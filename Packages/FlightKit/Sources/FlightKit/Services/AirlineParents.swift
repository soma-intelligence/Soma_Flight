import Foundation

/// Operators that fly another airline's livery and mark: regional brands under a mainline name (American
/// Eagle, Lufthansa CityLine), group AOCs that paint their aircraft like the parent (easyJet Europe, Malta
/// Air, Wizz Air UK), and country subsidiaries of one brand (LATAM Peru). When the bundle has no side
/// view, logo or fin of the operator itself, the parent's answers before any plain view or neutral mark.
///
/// Only operators whose aircraft carry the parent's livery belong here: Austrian or SWISS are Lufthansa
/// Group airlines with their own colours, so they never fall back to Lufthansa's art.
public enum AirlineParents {
    /// Operator ICAO code to the ICAO code of the airline whose livery it flies.
    public static let parent: [String: String] = [
        // Lufthansa, Air France, British Airways, Aer Lingus, Eurowings
        "LHX": "DLH", "CLH": "DLH", "HOP": "AFR", "CFE": "BAW", "EFW": "BAW", "EAI": "EIN", "EWL": "EWG",
        // Low-cost group AOCs
        "EJU": "EZY", "EZS": "EZY", "RYS": "RYR", "RUK": "RYR", "MAY": "RYR", "LDM": "RYR",
        "WUK": "WZZ", "WMT": "WZZ", "NSZ": "NOZ", "SZS": "SAS", "TVF": "TRA", "JJP": "JST",
        "AIQ": "AXM", "AWQ": "AXM", "APG": "AXM", "XAX": "AXM", "TAX": "XAX",
        "ADY": "ABY", "MAC": "ABY", "RBG": "ABY",
        // North American regional brands
        "ENY": "AAL", "PDT": "AAL", "JIA": "AAL", "AWI": "AAL", "FLG": "DAL", "ASH": "UAL", "GJS": "UAL",
        "UCA": "UAL", "ASQ": "UAL", "QXE": "ASA", "JZA": "ACA", "WEN": "WJA", "SLI": "AMX",
        // Asia-Pacific and Latin America
        "QLK": "QFA", "AKX": "ANA", "JLJ": "JAL", "JTA": "JAL", "SRQ": "CEB", "GAP": "PAL",
        "TAM": "LAN", "LPE": "LAN", "ARE": "LAN", "LNE": "LAN", "JES": "JAT",
        "KLC": "KLM",
    ]

    /// The operator, then the airlines whose livery it flies, nearest first ("TAX", "XAX", "AXM").
    public static func chain(_ icao: String) -> [String] {
        var code = icao.trimmingCharacters(in: .whitespaces).uppercased()
        var out = [code]
        while let next = parent[code], !out.contains(next) {
            out.append(next)
            code = next
        }
        return out
    }
}
