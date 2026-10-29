import json, uuid, random, datetime as dt, sys
OUT=sys.argv[1]
REF=dt.datetime(2026,10,23,15,42,0,tzinfo=dt.timezone.utc)
random.seed(7)
def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%S.000Z") if d else None
def mins(m): return dt.timedelta(minutes=m)
def uid(s): return str(uuid.uuid5(uuid.NAMESPACE_URL,"soma-flight-fake/"+s))
AP={ # icao: iata,name,city,country,lat,lon,tz
"KAUS":("AUS","Austin-Bergstrom International","Austin","US",30.1945,-97.6699,"America/Chicago"),
"KSFO":("SFO","San Francisco International","San Francisco","US",37.6213,-122.3790,"America/Los_Angeles"),
"KOAK":("OAK","Oakland International","Oakland","US",37.7213,-122.2208,"America/Los_Angeles"),
"LFPG":("CDG","Paris Charles de Gaulle","Paris","FR",49.0097,2.5479,"Europe/Paris"),
"KDFW":("DFW","Dallas Fort Worth International","Dallas","US",32.8998,-97.0403,"America/Chicago"),
"KDEN":("DEN","Denver International","Denver","US",39.8561,-104.6737,"America/Denver"),
"KATL":("ATL","Hartsfield-Jackson Atlanta International","Atlanta","US",33.6407,-84.4277,"America/New_York"),
"KJFK":("JFK","John F. Kennedy International","New York","US",40.6413,-73.7781,"America/New_York"),
"KORD":("ORD","Chicago O'Hare International","Chicago","US",41.9742,-87.9073,"America/Chicago"),
"KLAX":("LAX","Los Angeles International","Los Angeles","US",33.9416,-118.4085,"America/Los_Angeles"),
"KSEA":("SEA","Seattle-Tacoma International","Seattle","US",47.4502,-122.3088,"America/Los_Angeles"),
"KPHX":("PHX","Phoenix Sky Harbor International","Phoenix","US",33.4342,-112.0116,"America/Phoenix"),
"KHOU":("HOU","Houston Hobby","Houston","US",29.6454,-95.2789,"America/Chicago"),
"KIAH":("IAH","Houston George Bush Intercontinental","Houston","US",29.9902,-95.3368,"America/Chicago"),
"KLAS":("LAS","Harry Reid International","Las Vegas","US",36.0840,-115.1537,"America/Los_Angeles"),
"KBOS":("BOS","Boston Logan International","Boston","US",42.3656,-71.0096,"America/New_York"),
"EGLL":("LHR","London Heathrow","London","GB",51.4700,-0.4543,"Europe/London"),
"RJTT":("HND","Tokyo Haneda","Tokyo","JP",35.5494,139.7798,"Asia/Tokyo"),
"KPDX":("PDX","Portland International","Portland","US",45.5898,-122.5951,"America/Los_Angeles"),
"KSAN":("SAN","San Diego International","San Diego","US",32.7338,-117.1933,"America/Los_Angeles"),
"KMSY":("MSY","Louis Armstrong New Orleans International","New Orleans","US",29.9934,-90.2580,"America/Chicago"),
"KBNA":("BNA","Nashville International","Nashville","US",36.1263,-86.6774,"America/Chicago"),
"KMIA":("MIA","Miami International","Miami","US",25.7959,-80.2870,"America/New_York"),
"KELP":("ELP","El Paso International","El Paso","US",31.8072,-106.3776,"America/Denver"),
"KTPA":("TPA","Tampa International","Tampa","US",27.9755,-82.5332,"America/New_York"),
"KBWI":("BWI","Baltimore Washington International","Baltimore","US",39.1754,-76.6683,"America/New_York"),
"KSLC":("SLC","Salt Lake City International","Salt Lake City","US",40.7899,-111.9791,"America/Denver"),
"KBUR":("BUR","Hollywood Burbank","Burbank","US",34.2007,-118.3587,"America/Los_Angeles"),
"KEWR":("EWR","Newark Liberty International","Newark","US",40.6895,-74.1745,"America/New_York"),
"KMCO":("MCO","Orlando International","Orlando","US",28.4312,-81.3081,"America/New_York"),
"KCLT":("CLT","Charlotte Douglas International","Charlotte","US",35.2140,-80.9431,"America/New_York"),
"KABQ":("ABQ","Albuquerque International Sunport","Albuquerque","US",35.0402,-106.6090,"America/Denver"),
"KSJC":("SJC","San Jose International","San Jose","US",37.3639,-121.9289,"America/Los_Angeles"),
"MMMX":("MEX","Mexico City International","Mexico City","MX",19.4363,-99.0721,"America/Mexico_City"),
"MMUN":("CUN","Cancun International","Cancun","MX",21.0365,-86.8771,"America/Cancun"),
"CYYZ":("YYZ","Toronto Pearson International","Toronto","CA",43.6777,-79.6248,"America/Toronto"),
}
IATA={v[0]:k for k,v in AP.items()}
airports=[dict(id=k,iata=v[0],name=v[1],city=v[2],country=v[3],lat=v[4],lon=v[5],tz=v[6]) for k,v in AP.items()]
AL={"AA":("AAL","A321"),"UA":("UAL","B739"),"DL":("DAL","A320"),"WN":("SWA","B738"),"AS":("ASA","B739"),"B6":("JBU","A320"),"AF":("AFR","A359"),"BA":("BAW","B789"),"NK":("NKS","A320"),"F9":("FFT","A320")}
def flight(key,ident,orig,dest,sout,sin,status,delay=0,**kw):
    al=ident[:2]; op,ac=AL.get(al,(None,"A320"))
    f=dict(id=uid(key),provider_id=f"{ident}-{key}",ident=ident,operator=op,
      origin_icao=orig,origin_iata=AP[orig][0],destination_icao=dest,destination_iata=AP[dest][0],
      scheduled_out=iso(sout),scheduled_in=iso(sin),aircraft_type=ac,status=status,updated_at=iso(REF-mins(3)))
    if status in("scheduled",) and delay: f["estimated_out"]=iso(sout+mins(delay)); f["estimated_in"]=iso(sin+mins(delay))
    if status in("departed","en_route","landed","arrived"):
        f["actual_out"]=iso(sout+mins(delay)); f["actual_off"]=iso(sout+mins(delay+14))
        f["estimated_out"]=f["actual_out"]; f["estimated_in"]=iso(sin+mins(delay))
    if status in("landed","arrived"):
        f["actual_on"]=iso(sin+mins(delay-6)); f["actual_in"]=iso(sin+mins(delay))
    f.update({k:v for k,v in kw.items() if v is not None})
    return {k:v for k,v in f.items() if v is not None}
# followed
af=json.load(open(sys.argv[2]))
af["scheduled_out"]=iso(REF-mins(272)); af["scheduled_in"]=iso(REF+mins(398)); af["estimated_out"]=iso(REF-mins(257)); af["estimated_in"]=iso(REF+mins(409))
af["actual_out"]=iso(REF-mins(256)); af["actual_off"]=iso(REF-mins(239)); af["position_at"]=iso(REF-mins(0)); af["updated_at"]=iso(REF)
followed=[af,
 flight("ua1527","UA1527","KSFO","KAUS",REF+mins(220),REF+mins(405),"scheduled",12,gate_origin="F11",terminal_origin="3",registration="N37522"),
 flight("as312","AS312","KSEA","KSFO",REF+mins(1140),REF+mins(1262),"scheduled",0,gate_origin="C14",terminal_destination="2"),
 flight("dl2204","DL2204","KATL","KAUS",REF+mins(95),REF+mins(215),"canceled",0,gate_origin="B9"),
 flight("wn4410","WN4410","KLAX","KSFO",REF-mins(135),REF-mins(65),"diverted",0,
        **{}),
]
dv=followed[-1]; dv["destination_icao"]="KOAK"; dv["destination_iata"]="OAK"
dv["actual_out"]=iso(REF-mins(130)); dv["actual_off"]=iso(REF-mins(116)); dv["actual_on"]=iso(REF-mins(48)); dv["actual_in"]=iso(REF-mins(42))
dv["estimated_in"]=iso(REF-mins(42)); dv["gate_destination"]="14"; dv["registration"]="N8731J"; dv["aircraft_type"]="B38M"
followed[2]["registration"]="N284AK"
json.dump(followed,open(OUT+"/followed.json","w"),indent=1)
# boards: about 150 departures and 150 arrivals per airport over the local day, delays building
# through the afternoon. Stats come from the core's reference rules (core/fixtures/gen_delay.py).
import ast, os, zoneinfo
_core=os.path.join(os.path.dirname(os.path.abspath(__file__)),"../../../core/fixtures/gen_delay.py")
_tree=ast.parse(open(_core).read())
_ns={}
exec(compile(ast.Module(body=[n for n in _tree.body if isinstance(n,ast.FunctionDef) and n.name in("delay_sec","stats")]
  +[n for n in _tree.body if isinstance(n,ast.Assign) and getattr(n.targets[0],"id","")=="H"],type_ignores=[]),_core,"exec"),_ns)
core_stats=_ns["stats"]
dests=["KDFW","KDEN","KATL","KJFK","KORD","KLAX","KSEA","KPHX","KHOU","KIAH","KLAS","KBOS","KSFO","KSAN","KPDX",
       "KMSY","KBNA","KMIA","KELP","KTPA","KBWI","KSLC","KBUR","KEWR","KMCO","KCLT","KABQ","KSJC","MMMX","MMUN","CYYZ","KAUS"]
CARRIERS=["WN","WN","WN","AA","AA","UA","DL","DL","AS","B6","NK","F9"]
TAKEN={"AF84","UA1527","AS312","DL2204","WN4410"}
# per local hour: traffic weight. Mean delay follows a smooth curve through the day (minutes,
# by local fractional hour) that each airport scales: a slow morning, delays building all afternoon.
PROFILE={5:3,6:9,7:10,8:11,9:9,10:10,11:9,12:10,13:10,14:11,15:10,16:11,17:12,18:11,19:10,20:9,21:6,22:3}
CURVE=[(5,8),(8,14),(10,30),(12,42),(14,55),(16,68),(18,80),(20,72),(23,55)]
def mean_delay(hf):
    for (h0,m0),(h1,m1) in zip(CURVE,CURVE[1:]):
        if hf<=h1: return m0+(m1-m0)*max(0,(hf-h0))/(h1-h0)
    return CURVE[-1][1]
def dense_board(icao,kind,n,severity_scale,rng):
    tz=zoneinfo.ZoneInfo(AP[icao][6])
    day=REF.astimezone(tz).replace(hour=0,minute=0,second=0,microsecond=0)
    hours=list(PROFILE); weights=[PROFILE[h] for h in hours]
    slots=sorted(rng.choices(hours,weights=weights,k=n))
    fl=[]; used=set()
    for i,h in enumerate(slots):
        while True:
            al=rng.choice(CARRIERS); ident=f"{al}{rng.randint(100,4999)}"
            if ident not in TAKEN and ident not in used: used.add(ident); break
        other=rng.choice([d for d in dests if d!=icao])
        minute=rng.choice(range(0,60,5))
        t=(day+dt.timedelta(hours=h,minutes=minute)).astimezone(dt.timezone.utc)
        dur=rng.randint(70,240)
        if kind=="departures": o,d,so,si=icao,other,t,t+mins(dur)
        else: o,d,so,si=other,icao,t-mins(dur),t
        mean=mean_delay(h+minute/60)*severity_scale
        if rng.random()<0.025: st="canceled"; delay=0
        else:
            # a quarter of flights get away on time whatever the day looks like
            delay=rng.choice([-4,-2,0,0,2,5,9]) if rng.random()<0.25 else max(-3,int(rng.gauss(mean,mean*0.35+4)))
            gate_t=(so if kind=="departures" else si)+mins(delay)
            dep_t=so+mins(delay)
            if kind=="departures": st="departed" if gate_t<REF else "scheduled"
            elif gate_t<REF: st="arrived" if gate_t<REF-mins(20) else "landed"
            elif dep_t<REF: st="en_route"
            else: st="scheduled"
        key=f"{icao}-{kind}-{i}"
        f=flight(key,ident,o,d,so,si,st,delay)
        if st=="scheduled": f["estimated_out"]=iso(so+mins(delay)); f["estimated_in"]=iso(si+mins(delay))
        if st=="en_route": f["actual_out"]=iso(so+mins(delay)); f["actual_off"]=iso(so+mins(delay+14)); f["estimated_in"]=iso(si+mins(delay))
        if kind=="departures": f["gate_origin"]=rng.choice("ABCDE")+str(rng.randint(1,30)) if icao=="KSFO" else str(rng.randint(1,36))
        else:
            f["gate_destination"]=str(rng.randint(1,36)); f["baggage_belt"]=str(rng.randint(1,4))
        fl.append(f)
    fl.sort(key=lambda f:(f["scheduled_out" if kind=="departures" else "scheduled_in"],f["ident"]))
    return dict(icao=icao,kind=kind,fetched_at=iso(REF-mins(2)),stale=False,flights=fl)
_rng=random.Random(23)
SCALE={("KAUS","departures"):1.0,("KAUS","arrivals"):1.4,("KSFO","departures"):0.28,("KSFO","arrivals"):0.28}
COUNT={("KAUS","departures"):152,("KAUS","arrivals"):148,("KSFO","departures"):156,("KSFO","arrivals"):150}
boards=[dense_board(a,k,COUNT[(a,k)],SCALE[(a,k)],_rng) for a in("KAUS","KSFO") for k in("departures","arrivals")]
json.dump(boards,open(OUT+"/boards.json","w"),indent=1)
def epoch(s): return int(dt.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()) if s else None
def rows(b,kind):
    sfx="out" if kind=="departures" else "in"
    other="destination_icao" if kind=="departures" else "origin_icao"
    return [dict(ident=f["ident"],operator=f.get("operator"),other_icao=f[other],status=f["status"],
                 scheduled=epoch(f.get("scheduled_"+sfx)),estimated=epoch(f.get("estimated_"+sfx)),actual=epoch(f.get("actual_"+sfx))) for f in b]
def stats(icao):
    return {k:core_stats(rows([x for x in boards if x["icao"]==icao and x["kind"]==k][0]["flights"],k)) for k in("departures","arrivals")}
json.dump({a:stats(a) for a in("KAUS","KSFO")},open(OUT+"/stats.json","w"),indent=1)
# weather
wx=json.load(open(sys.argv[3]))
sf=dict(metarRaw="KSFO 232356Z 29014KT 10SM FEW015 SCT200 17/11 A3002",tafRaw="KSFO 232320Z 2400/2506 28012KT P6SM FEW015",tempC=17.0,windDirDeg=290,windKt=14,gustKt=None,visibilitySm=10.0,ceilingFt=None,category="VFR",observedAt=iso(REF-mins(18)),
  forecast=[dict(**{"from":iso(REF+mins(18)),"to":iso(REF+mins(378)),"category":"MVFR","windDirDeg":280,"windKt":12,"gustKt":20,"visibilitySm":4.0,"ceilingFt":1500})])
wx["observedAt"]=iso(REF-mins(32)); wx["forecast"][0]["from"]=iso(REF+mins(18)); wx["forecast"][0]["to"]=iso(REF+mins(378))
json.dump({"KAUS":wx,"KSFO":sf},open(OUT+"/weather.json","w"),indent=1)
json.dump(airports,open(OUT+"/airports.json","w"),indent=1)
# past flights
P=[("2026-09-14","AF83","KSFO","LFPG","Air France","A359","F-HTYB","41K",8970,640,12,"completed"),
("2026-07-02","UA1527","KAUS","KSFO","United","B739","N37522","18A",2400,235,0,"completed"),
("2026-05-19","DL2204","KATL","KAUS","Delta","A321","N370DN","22C",1280,125,38,"completed"),
("2026-03-08","BA286","EGLL","KSFO","British Airways","B789","G-ZBKA","33A",8620,640,5,"completed"),
("2025-12-21","WN4410","KLAX","KSFO","Southwest","B38M","N8731J","14F",543,80,0,"canceled"),
("2025-08-11","AS312","KSEA","KSFO","Alaska","B739","N284AK","9D",1090,125,21,"completed"),
("2025-02-27","UA837","KSFO","RJTT","United","B789","N29975","27L",8250,665,0,"completed"),
("2024-10-05","B6417","KBOS","KJFK","JetBlue","A220","N3057J","6B",300,70,-3,"diverted")]
past=[dict(id=uid("past"+p[1]+p[0]),date=p[0]+"T12:00:00.000Z",ident=p[1],origin_icao=p[2],destination_icao=p[3],airline=p[4],aircraft_type=p[5],registration=p[6],seat=p[7],distance_km=p[8],block_minutes=p[9],delay_minutes=p[10],status=p[11]) for p in P]
json.dump(past,open(OUT+"/past_flights.json","w"),indent=1)
