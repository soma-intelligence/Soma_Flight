//! Weather impact: whether the weather in a METAR or a TAF period is likely slowing an
//! airport, which side of the operation it hits, and a short reason in plain English.
//!
//! The thresholds are rules of thumb from how airports run, not an official product:
//! - Low clouds and poor visibility force instrument approaches with wider spacing, so
//!   arrivals slow first. Below about 1 sm departures need their own minima too.
//! - Strong winds and gusts cut the usable runways and widen spacing on final.
//! - Thunderstorms stop ramp work and close departure and arrival routes.
//! - Snow, freezing precipitation and freezing fog mean de-icing and runway clearing.
//!
//! Pure: no clock, no I/O. Present weather is read from the METAR/TAF groups ("-RA",
//! "+TSRA", "VCSH", "FZFG").

use serde::{Deserialize, Serialize};

/// What the impact reads. Missing values are unknown and never make anything worse.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conditions {
    /// Lowest BKN, OVC or VV layer in feet; None is unlimited or unknown.
    pub ceiling_ft: Option<i32>,
    pub visibility_sm: Option<f64>,
    pub wind_kt: Option<i32>,
    pub gust_kt: Option<i32>,
    /// Present weather groups separated by spaces, as in a report ("-RA BR"). Anything that is
    /// not a weather group is ignored, so a whole report body works too (see `present_weather`).
    #[serde(default)]
    pub wx: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImpactLevel {
    /// Nothing in the weather that should slow flights.
    None,
    /// Worth a mention; small delays at the busiest hours at most.
    Minor,
    /// Likely slowing the airport.
    Moderate,
    /// Likely holding flights or cutting the airport's rate hard.
    Severe,
}

/// Which side of the operation the weather hits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Affects {
    Arrivals,
    Departures,
    Both,
}

impl Affects {
    fn merge(self, other: Affects) -> Affects {
        if self == other { self } else { Affects::Both }
    }
}

/// One weather factor, in the order the reason names them (most disruptive first).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HazardKind {
    Thunderstorm,
    FreezingPrecip,
    Snow,
    LowCeiling,
    Fog,
    LowVisibility,
    Wind,
    HeavyRain,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hazard {
    pub kind: HazardKind,
    pub level: ImpactLevel,
    pub affects: Affects,
    /// Lowercase noun phrase for sentences: "low clouds", "thunderstorms nearby".
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Impact {
    /// The worst hazard's level, `None` without hazards.
    pub level: ImpactLevel,
    /// True from `Moderate` up: the weather is likely slowing the airport.
    pub slows: bool,
    /// Side hit by the hazards at the verdict's level; None without hazards.
    pub affects: Option<Affects>,
    /// Every hazard found, most disruptive kind first.
    pub hazards: Vec<Hazard>,
    /// One line: "Low clouds and fog: arrivals likely slowed".
    pub reason: String,
}

// MARK: Present weather groups

const DESCRIPTORS: [&str; 8] = ["MI", "PR", "BC", "DR", "BL", "SH", "TS", "FZ"];
const PHENOMENA: [&str; 22] = [
    "DZ", "RA", "SN", "SG", "IC", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA", "HZ",
    "PY", "PO", "SQ", "FC", "SS", "DS",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Intensity {
    Light,
    Moderate,
    Heavy,
    Vicinity,
}

/// One parsed group such as "+TSRA".
#[derive(Debug, Clone, PartialEq, Eq)]
struct Group {
    intensity: Intensity,
    descriptor: Option<&'static str>,
    phenomena: Vec<&'static str>,
}

impl Group {
    fn has(&self, code: &str) -> bool {
        self.phenomena.contains(&code)
    }

    fn is(&self, descriptor: &str) -> bool {
        self.descriptor == Some(descriptor)
    }

    fn precip(&self) -> bool {
        self.phenomena
            .iter()
            .any(|p| matches!(*p, "DZ" | "RA" | "SN" | "SG" | "PL" | "GR" | "GS" | "UP"))
    }
}

fn pick(table: &[&'static str], code: &str) -> Option<&'static str> {
    table.iter().copied().find(|t| *t == code)
}

/// A present weather group, or None for anything else (wind, clouds, NSW, recent weather "RERA").
fn parse_group(token: &str) -> Option<Group> {
    let (intensity, mut rest) = if let Some(r) = token.strip_prefix('+') {
        (Intensity::Heavy, r)
    } else if let Some(r) = token.strip_prefix('-') {
        (Intensity::Light, r)
    } else if let Some(r) = token.strip_prefix("VC") {
        (Intensity::Vicinity, r)
    } else {
        (Intensity::Moderate, token)
    };
    if rest.len() % 2 != 0 || !rest.is_ascii() {
        return None;
    }
    let mut descriptor = None;
    if rest.len() >= 2
        && let Some(d) = pick(&DESCRIPTORS, &rest[..2])
    {
        descriptor = Some(d);
        rest = &rest[2..];
    }
    let mut phenomena = Vec::new();
    while !rest.is_empty() {
        phenomena.push(pick(&PHENOMENA, &rest[..2])?);
        rest = &rest[2..];
    }
    // A descriptor stands alone only for thunder ("TS", "VCTS") and nearby showers ("VCSH").
    let valid = match (descriptor, phenomena.is_empty()) {
        (None, true) => false,
        (Some("TS"), true) => true,
        (Some("SH"), true) => intensity == Intensity::Vicinity,
        (Some(_), true) => false,
        _ => true,
    };
    valid.then_some(Group {
        intensity,
        descriptor,
        phenomena,
    })
}

fn groups(wx: &str) -> Vec<Group> {
    wx.split_whitespace().filter_map(parse_group).collect()
}

/// The present weather groups of a METAR body, space separated ("-RA BR"). Skips the report
/// type and station, and stops at the remarks and at trend groups (TEMPO, BECMG, NOSIG) so a
/// forecast change is never read as current weather.
pub fn present_weather(report: &str) -> String {
    let mut tokens = report.split_whitespace().peekable();
    if matches!(tokens.peek(), Some(&("METAR" | "SPECI" | "TAF"))) {
        tokens.next();
    }
    tokens.next(); // station
    tokens
        .take_while(|t| !matches!(*t, "RMK" | "TEMPO" | "BECMG" | "NOSIG"))
        .filter(|t| parse_group(t).is_some())
        .collect::<Vec<_>>()
        .join(" ")
}

fn phenomenon_name(code: &str) -> &'static str {
    match code {
        "DZ" => "drizzle",
        "RA" => "rain",
        "SN" => "snow",
        "SG" => "snow grains",
        "IC" => "ice crystals",
        "PL" => "ice pellets",
        "GR" => "hail",
        "GS" => "small hail",
        "UP" => "precipitation",
        "BR" => "mist",
        "FG" => "fog",
        "FU" => "smoke",
        "VA" => "volcanic ash",
        "DU" => "dust",
        "SA" => "sand",
        "HZ" => "haze",
        "PY" => "spray",
        "PO" => "dust whirls",
        "SQ" => "squalls",
        "FC" => "a funnel cloud",
        "SS" => "a sandstorm",
        "DS" => "a dust storm",
        _ => "weather",
    }
}

fn join_and(parts: &[String]) -> String {
    match parts {
        [] => String::new(),
        [one] => one.clone(),
        [init @ .., last] => format!("{} and {}", init.join(", "), last),
    }
}

fn describe_group(g: &Group) -> String {
    let names: Vec<String> = g
        .phenomena
        .iter()
        .map(|p| phenomenon_name(p).to_string())
        .collect();
    let what = join_and(&names);
    let strength = match g.intensity {
        Intensity::Light => "light ",
        Intensity::Heavy => "heavy ",
        _ => "",
    };
    let core = match g.descriptor {
        Some("TS") if what.is_empty() => "thunderstorms".to_string(),
        Some("TS") => format!("thunderstorms with {strength}{what}"),
        Some("SH") if what.is_empty() => "showers".to_string(),
        Some("SH") => format!("{strength}{what} showers"),
        Some("FZ") => format!("{strength}freezing {what}"),
        Some("BL") => format!("blowing {what}"),
        Some("DR") => format!("drifting {what}"),
        Some("MI") => format!("shallow {what}"),
        Some("BC") => format!("patches of {what}"),
        Some("PR") => format!("partial {what}"),
        _ => format!("{strength}{what}"),
    };
    if g.intensity == Intensity::Vicinity {
        format!("{core} nearby")
    } else {
        core
    }
}

/// Plain English for present weather groups: "-RA BR" is "light rain and mist", "+TSRA" is
/// "thunderstorms with heavy rain". Empty when there is no weather group.
pub fn describe_weather(wx: &str) -> String {
    let parts: Vec<String> = groups(wx).iter().map(describe_group).collect();
    join_and(&parts)
}

// MARK: Impact

fn hazard(kind: HazardKind, level: ImpactLevel, affects: Affects, label: &str) -> Hazard {
    Hazard {
        kind,
        level,
        affects,
        label: label.to_string(),
    }
}

fn weather_hazards(gs: &[Group], out: &mut Vec<Hazard>) {
    use ImpactLevel::{Minor, Moderate, Severe};
    let on_field = |g: &&Group| g.intensity != Intensity::Vicinity;

    // Thunderstorms: on the field they stop the ramp and close routes; nearby they still bend
    // arrival and departure paths.
    if gs.iter().filter(on_field).any(|g| g.is("TS")) {
        out.push(hazard(
            HazardKind::Thunderstorm,
            Severe,
            Affects::Both,
            "thunderstorms",
        ));
    } else if gs.iter().any(|g| g.is("TS")) {
        out.push(hazard(
            HazardKind::Thunderstorm,
            Moderate,
            Affects::Both,
            "thunderstorms nearby",
        ));
    }

    // Freezing precipitation and ice pellets: de-icing and slick runways.
    let fz_precip = gs
        .iter()
        .filter(on_field)
        .find(|g| (g.is("FZ") && g.precip()) || g.has("PL"));
    if let Some(g) = fz_precip {
        let label = if g.has("PL") && !g.is("FZ") {
            "ice pellets"
        } else if g.has("DZ") && !g.has("RA") {
            "freezing drizzle"
        } else {
            "freezing rain"
        };
        out.push(hazard(
            HazardKind::FreezingPrecip,
            Severe,
            Affects::Both,
            label,
        ));
    }

    // Snow: heavy snow closes runways for clearing; any snow means de-icing.
    let snow: Vec<&Group> = gs
        .iter()
        .filter(on_field)
        .filter(|g| (g.has("SN") || g.has("SG")) && !g.is("DR"))
        .collect();
    if snow.iter().any(|g| g.intensity == Intensity::Heavy) {
        out.push(hazard(
            HazardKind::Snow,
            Severe,
            Affects::Both,
            "heavy snow",
        ));
    } else if snow.iter().any(|g| g.is("BL")) {
        out.push(hazard(
            HazardKind::Snow,
            Severe,
            Affects::Both,
            "blowing snow",
        ));
    } else if !snow.is_empty() {
        out.push(hazard(HazardKind::Snow, Moderate, Affects::Both, "snow"));
    }

    // Fog on the field (not shallow, patchy or partial: those burn off and rarely set minima).
    let fog = gs
        .iter()
        .filter(on_field)
        .find(|g| g.has("FG") && g.descriptor.is_none_or(|d| d == "FZ"));
    if let Some(g) = fog {
        if g.is("FZ") {
            out.push(hazard(
                HazardKind::Fog,
                Moderate,
                Affects::Both,
                "freezing fog",
            ));
        } else {
            out.push(hazard(HazardKind::Fog, Moderate, Affects::Arrivals, "fog"));
        }
    }

    // Heavy rain: worth a mention on its own; the visibility it brings is counted separately.
    if gs
        .iter()
        .filter(on_field)
        .any(|g| g.intensity == Intensity::Heavy && g.has("RA") && !g.is("TS") && !g.is("FZ"))
    {
        out.push(hazard(
            HazardKind::HeavyRain,
            Minor,
            Affects::Arrivals,
            "heavy rain",
        ));
    }
}

fn ceiling_hazard(ceiling_ft: Option<i32>) -> Option<Hazard> {
    use ImpactLevel::{Minor, Moderate, Severe};
    let ft = ceiling_ft?;
    let (level, label) = if ft < 500 {
        (Severe, "very low clouds")
    } else if ft < 1000 {
        (Moderate, "low clouds")
    } else if ft <= 3000 {
        (Minor, "a low cloud deck")
    } else {
        return None;
    };
    Some(hazard(
        HazardKind::LowCeiling,
        level,
        Affects::Arrivals,
        label,
    ))
}

fn visibility_hazard(visibility_sm: Option<f64>) -> Option<Hazard> {
    use ImpactLevel::{Minor, Moderate, Severe};
    let sm = visibility_sm.filter(|v| v.is_finite() && *v >= 0.0)?;
    let (level, affects, label) = if sm < 1.0 {
        (Severe, Affects::Both, "very poor visibility")
    } else if sm < 3.0 {
        (Moderate, Affects::Arrivals, "poor visibility")
    } else if sm <= 5.0 {
        (Minor, Affects::Arrivals, "reduced visibility")
    } else {
        return None;
    };
    Some(hazard(HazardKind::LowVisibility, level, affects, label))
}

fn wind_hazard(wind_kt: Option<i32>, gust_kt: Option<i32>) -> Option<Hazard> {
    use ImpactLevel::{Minor, Moderate, Severe};
    let wind = wind_kt.unwrap_or(0);
    // A gust below the steady wind is bad data; read it as no gust.
    let gust = gust_kt.unwrap_or(0).max(wind);
    let (level, label) = if gust >= 40 || wind >= 35 {
        (
            Severe,
            if gust >= 40 && gust > wind {
                "very strong gusts"
            } else {
                "very strong winds"
            },
        )
    } else if gust >= 30 || wind >= 25 {
        (
            Moderate,
            if gust >= 30 && gust > wind {
                "strong gusts"
            } else {
                "strong winds"
            },
        )
    } else if gust >= 25 || wind >= 20 {
        (
            Minor,
            if gust >= 25 && gust > wind {
                "gusty winds"
            } else {
                "brisk winds"
            },
        )
    } else {
        return None;
    };
    Some(hazard(HazardKind::Wind, level, Affects::Arrivals, label))
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn reason(level: ImpactLevel, affects: Option<Affects>, named: &[&Hazard]) -> String {
    let Some(affects) = affects else {
        return "No weather likely to slow flights".to_string();
    };
    let labels: Vec<String> = named.iter().take(2).map(|h| h.label.clone()).collect();
    let what = capitalized(&join_and(&labels));
    let side = match affects {
        Affects::Arrivals => "arrivals",
        Affects::Departures => "departures",
        Affects::Both => "departures and arrivals",
    };
    let effect = match level {
        ImpactLevel::Severe => format!("{side} likely held up"),
        ImpactLevel::Moderate => format!("{side} likely slowed"),
        _ => "small delays possible".to_string(),
    };
    format!("{what}: {effect}")
}

/// Reads the conditions and says whether the weather is likely slowing the airport.
pub fn weather_impact(c: &Conditions) -> Impact {
    let gs = groups(&c.wx);
    let mut hazards = Vec::new();
    weather_hazards(&gs, &mut hazards);
    hazards.extend(ceiling_hazard(c.ceiling_ft));
    // Fog already says the visibility is poor: name it once.
    let fog = hazards.iter().any(|h| h.kind == HazardKind::Fog);
    if let Some(v) = visibility_hazard(c.visibility_sm) {
        match hazards.iter_mut().find(|h| h.kind == HazardKind::Fog) {
            // Thick fog takes the visibility's level and reach.
            Some(f) if v.level > f.level => {
                f.level = v.level;
                f.affects = f.affects.merge(v.affects);
                if f.label == "fog" && v.level == ImpactLevel::Severe {
                    f.label = "thick fog".to_string();
                }
            }
            _ if fog => {}
            _ => hazards.push(v),
        }
    }
    hazards.extend(wind_hazard(c.wind_kt, c.gust_kt));
    hazards.sort_by_key(|h| h.kind);

    let level = hazards
        .iter()
        .map(|h| h.level)
        .max()
        .unwrap_or(ImpactLevel::None);
    // The verdict names what drives it: the hazards at its own level.
    let named: Vec<&Hazard> = hazards.iter().filter(|h| h.level == level).collect();
    let affects = named.iter().map(|h| h.affects).reduce(Affects::merge);
    Impact {
        level,
        slows: level >= ImpactLevel::Moderate,
        affects,
        reason: reason(level, affects, &named),
        hazards,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wx(s: &str) -> Conditions {
        Conditions {
            wx: s.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn groups_parse_strictly() {
        for ok in [
            "-RA", "+TSRA", "VCSH", "TS", "VCTS", "FZFG", "BR", "-SHSN", "RASN", "BLSN",
        ] {
            assert!(parse_group(ok).is_some(), "{ok}");
        }
        for no in [
            "KAUS", "10SM", "BKN009", "RMK", "SH", "FZ", "NSW", "RERA", "A3015", "CAVOK", "9999",
        ] {
            assert!(parse_group(no).is_none(), "{no}");
        }
    }

    #[test]
    fn present_weather_skips_station_trend_and_remarks() {
        assert_eq!(
            present_weather("SPECI KAUS 291744Z VRB03KT 10SM -RA BKN009 22/20 A3015 RMK AO2 TSB12"),
            "-RA"
        );
        assert_eq!(
            present_weather(
                "LFPG 240600Z 00000KT 0300 R27L/0450N FG VV001 08/08 Q1021 TEMPO 1500 BR"
            ),
            "FG"
        );
    }

    #[test]
    fn calm_fine_weather_is_none() {
        let i = weather_impact(&Conditions {
            ceiling_ft: Some(25_000),
            visibility_sm: Some(10.0),
            wind_kt: Some(8),
            gust_kt: None,
            wx: String::new(),
        });
        assert_eq!(i.level, ImpactLevel::None);
        assert!(!i.slows);
        assert_eq!(i.affects, None);
        assert_eq!(i.reason, "No weather likely to slow flights");
    }

    #[test]
    fn vicinity_snow_is_not_snow_on_the_field() {
        assert_eq!(weather_impact(&wx("VCSN")).level, ImpactLevel::None);
    }

    #[test]
    fn bad_gust_is_ignored() {
        let i = weather_impact(&Conditions {
            wind_kt: Some(26),
            gust_kt: Some(10),
            ..Default::default()
        });
        assert_eq!(i.hazards[0].label, "strong winds");
    }
}
