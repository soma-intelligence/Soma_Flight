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
# boards
dests=["KDFW","KDEN","KATL","KJFK","KORD","KLAX","KSEA","KPHX","KHOU","KIAH","KLAS","KBOS","KSFO","KSAN","KPDX"]
def board(icao,kind):
    fl=[]
    others=[d for d in dests if d!=icao]
    for i in range(25):
        al=random.choice(["AA","UA","DL","WN","AS","B6","NK","F9"]); num=random.randint(100,2999)
        other=random.choice(others)
        off=-120+i*14+random.randint(-4,4)
        dur=random.randint(75,230)
        if kind=="departures": o,d,so,si=icao,other,REF+mins(off),REF+mins(off+dur)
        else: o,d,so,si=other,icao,REF+mins(off-dur),REF+mins(off)
        r=random.random(); delay=random.choice([0,0,0,3,8,17,25,40,62,95])
        key=f"{icao}-{kind}-{i}"
        ref_t=so if kind=="departures" else si
        if r<0.07: st="canceled"; delay=0
        elif ref_t<REF-mins(60): st="landed" if kind=="arrivals" else "departed"
        elif ref_t<REF: st="en_route" if kind=="arrivals" else "departed"
        else: st="scheduled"
        f=flight(key,f"{al}{num}",o,d,so,si,st,delay)
        if st in("landed","en_route","departed") and kind=="arrivals" and "actual_in" not in f and st=="landed":
            pass
        f["gate_origin" if kind=="departures" else "gate_destination"]=random.choice("ABCDE")+str(random.randint(1,30))
        fl.append(f)
    return dict(icao=icao,kind=kind,fetched_at=iso(REF-mins(2)),stale=False,flights=fl)
boards=[board(a,k) for a in("KAUS","KSFO") for k in("departures","arrivals")]
json.dump(boards,open(OUT+"/boards.json","w"),indent=1)
# stats
def stats(icao):
    out={}
    for kind in("departures","arrivals"):
        b=[x for x in boards if x["icao"]==icao and x["kind"]==kind][0]["flights"]
        tot=len(b); canc=sum(1 for f in b if f["status"]=="canceled")
        def dly(f):
            s=dt.datetime.fromisoformat(f["scheduled_out" if kind=="departures" else "scheduled_in"].replace("Z","+00:00"))
            e=f.get("estimated_out" if kind=="departures" else "estimated_in")
            if not e: return 0
            return int((dt.datetime.fromisoformat(e.replace("Z","+00:00"))-s).total_seconds()/60)
        ds=[dly(f) for f in b if f["status"]!="canceled"]
        late=sum(1 for d in ds if d>=15)
        base=int((REF-mins(180)).timestamp()//3600*3600)
        per=[]
        for h in range(8):
            chunk=b[h*3:(h+1)*3]
            ch=[dly(f) for f in chunk if f["status"]!="canceled"]
            per.append(dict(hour=base+h*3600,onTime=sum(1 for d in ch if d<15),late15=sum(1 for d in ch if 15<=d<45),late45=sum(1 for d in ch if d>=45),canceled=sum(1 for f in chunk if f["status"]=="canceled"),diverted=0))
        other="destination_icao" if kind=="departures" else "origin_icao"
        routes={};air={}
        for f in b:
            if f["status"]=="canceled" or dly(f)>=15 or True:
                if f["status"]=="canceled" or dly(f)>=15:
                    r=routes.setdefault(f[other],[0,0]); r[1 if f["status"]=="canceled" else 0]+=1
                    a=air.setdefault(f["operator"],[0,0]); a[1 if f["status"]=="canceled" else 0]+=1
        sev="major" if late/max(tot,1)>0.3 else "moderate" if late/max(tot,1)>0.15 else "normal"
        out[kind]=dict(total=tot,onTime=tot-late-canc,delayed15=late,canceled=canc,avgDelayMinutes=round(sum(ds)/max(len(ds),1),2),perHour=per,
          worstRoutes=[dict(icao=k,delayed=v[0],canceled=v[1]) for k,v in sorted(routes.items(),key=lambda x:-sum(x[1]))[:3]],
          worstAirlines=[dict(**{"operator":k},delayed=v[0],canceled=v[1]) for k,v in sorted(air.items(),key=lambda x:-sum(x[1]))[:3]],severity=sev)
    return out
json.dump({a:stats(a) for a in("KAUS","KSFO")},open(OUT+"/stats.json","w"),indent=1)
# weather
wx=json.load(open(sys.argv[3]))
sf=dict(metarRaw="KSFO 232356Z 29014KT 10SM FEW015 SCT200 17/11 A3002",tafRaw="KSFO 232320Z 2400/2506 28012KT P6SM FEW015",tempC=17.0,windDirDeg=290,windKt=14,gustKt=None,visibilitySm=10.0,ceilingFt=None,category="VFR",observedAt=iso(REF+mins(14)),
  forecast=[dict(**{"from":iso(REF+mins(18)),"to":iso(REF+mins(378)),"category":"MVFR","windDirDeg":280,"windKt":12,"gustKt":20,"visibilitySm":4.0,"ceilingFt":1500})])
wx["observedAt"]=iso(REF+mins(11)); wx["forecast"][0]["from"]=iso(REF+mins(18)); wx["forecast"][0]["to"]=iso(REF+mins(378))
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
