# Regenerates flighty_export.csv: python3 -I make_flighty_export.py flighty_export.csv
# Builds an invented export in the other tracker's 33 columns: every value is made up.
import random, uuid, datetime as dt, csv, io, sys
random.seed(20261031)
H="Date,Airline,Flight,From,To,Dep Terminal,Dep Gate,Arr Terminal,Arr Gate,Canceled,Diverted To,Gate Departure (Scheduled),Gate Departure (Actual),Take off (Scheduled),Take off (Actual),Landing (Scheduled),Landing (Actual),Gate Arrival (Scheduled),Gate Arrival (Actual),Aircraft Type Name,Tail Number,PNR,Seat,Seat Type,Cabin Class,Flight Reason,Notes,Flight Flighty ID,Airline Flighty ID,Departure Airport Flighty ID,Arrival Airport Flighty ID,Diverted To Airport Flighty ID,Aircraft Type Flighty ID".split(",")
routes=[("AFR","CDG","SFO",660),("AFR","SFO","CDG",650),("UAL","SFO","EWR",330),("UAL","EWR","SFO",380),("DAL","ATL","LAX",290),
("BAW","LHR","JFK",480),("BAW","JFK","LHR",420),("DLH","FRA","SIN",735),("KLM","AMS","NRT",700),("CPA","HKG","TPE",105),
("CPA","TPE","HKG",110),("SIA","SIN","SYD",470),("QFA","SYD","MEL",95),("ANA","HND","ITM",70),("EZY","LGW","NCE",115),
("RYR","STN","DUB",75),("AAL","DFW","ORD",145),("ASA","SEA","SFO",125),("JBU","BOS","FLL",205),("ACA","YYZ","YVR",300),
("IBE","MAD","BCN",80),("SWR","ZRH","GVA",55),("TAP","LIS","OPO",55),("THY","IST","ESB",75),("UAE","DXB","LHR",460)]
types=["Boeing 777-300ER","Airbus A320","Airbus A321neo","Boeing 737-900ER","Boeing 777-200 ER","Boeing 737 MAX 8","Airbus A350-900",
"Boeing 787-9","Embraer E190","Airbus A220-300","Boeing 737-800","Airbus A330-300","Bombardier CRJ900",""]
ids={k:str(uuid.UUID(int=random.getrandbits(128))) for k in set([r[0] for r in routes]+[r[1] for r in routes]+[r[2] for r in routes]+types)}
seats=["12A","32K","7C","14F","23D","12 A","7a","40L","3B",""]
notes=["","","","",'Window, great views','He said "welcome aboard"',"Line one\nline two","=SUM(A1)","Café au lait, merci"]
rows=[]
day=dt.date(2015,1,3)
def stamp(d,t): return (dt.datetime.combine(d,dt.time())+t).strftime("%Y-%m-%dT%H:%M")
for i in range(300):
    day+=dt.timedelta(days=random.randint(1,13))
    a,o,d,mins=random.choice(routes)
    out=dt.timedelta(hours=random.randint(5,22),minutes=random.choice([0,5,10,15,20,25,30,35,40,45,50,55]))
    delay=random.choice([0,0,0,5,12,25,48,-4,95])
    sched_out=stamp(day,out); act_out=stamp(day,out+dt.timedelta(minutes=delay))
    # local arrival in a made-up offset of the destination
    arr=out+dt.timedelta(minutes=mins+random.choice([-120,0,60,420,-360]))
    sched_in=stamp(day,arr); act_in=stamp(day,arr+dt.timedelta(minutes=delay+random.choice([-10,0,5])))
    if i%37==0: act_out+=":00"; act_in+=":00"
    canceled = i%53==7
    diverted = "OAK" if i%71==3 else ""
    t=random.choice(types)
    r={k:"" for k in H}
    r.update({"Date":day.isoformat(),"Airline":a,"Flight":str(random.randint(1,2999)) if i%41 else "0084","From":o,"To":d,
      "Dep Terminal":random.choice(["1","2E","A","Main",""]),"Dep Gate":random.choice(["B6","K41","12","",""]),
      "Arr Terminal":random.choice(["3","I","","Intl"]),"Arr Gate":random.choice(["C22","7","",""]),
      "Canceled":"true" if canceled else "false","Diverted To":diverted,
      "Gate Departure (Scheduled)":sched_out,"Gate Departure (Actual)":"" if canceled or i%19==0 else act_out,
      "Gate Arrival (Scheduled)":"" if i%29==0 else sched_in,"Gate Arrival (Actual)":"" if canceled or i%17==0 else act_in,
      "Aircraft Type Name":t,"Tail Number":random.choice(["","","N12345","F-GSQA","9V-SMA"]),
      "PNR":random.choice(["","QX4T7B","K2LM9P","ZZTOP1",""]),"Seat":random.choice(seats),
      "Seat Type":random.choice(["WINDOW","AISLE","MIDDLE",""]),"Cabin Class":random.choice(["ECONOMY","ECONOMY","PREMIUM_ECONOMY","BUSINESS","FIRST",""]),
      "Flight Reason":random.choice(["LEISURE","BUSINESS","PERSONAL",""]),"Notes":random.choice(notes),
      "Flight Flighty ID":str(uuid.UUID(int=random.getrandbits(128))),"Airline Flighty ID":ids[a],
      "Departure Airport Flighty ID":ids[o],"Arrival Airport Flighty ID":ids[d],
      "Diverted To Airport Flighty ID":str(uuid.UUID(int=random.getrandbits(128))) if diverted else "","Aircraft Type Flighty ID":ids.get(t,"") if t else ""})
    rows.append(r)
# Tricky rows at the end.
def extra(**kw):
    r={k:"" for k in H}; r["Canceled"]="false"; r.update(kw); rows.append(r)
extra(Date="2024-02-30",Airline="AFR",Flight="85",From="SFO",To="CDG")            # no such day
extra(Date="",Airline="AFR",Flight="85",From="SFO",To="CDG")                       # no date
extra(Date="2024-05-02",Airline="UAL",Flight="1",From="",To="SFO")                 # no origin
extra(Date="2024-05-03",Airline="UAL",Flight="2",From="XZQ",To="SFO",**{"Gate Departure (Scheduled)":"2024-05-03T09:00"})  # airport unknown to the list
extra(Date="2024-05-04",Airline="UAL",Flight="3",From="SFO",To="SFO")             # same airports
extra(Date=rows[10]["Date"],Airline=rows[10]["Airline"],Flight=rows[10]["Flight"],From=rows[10]["From"],To=rows[10]["To"])  # repeated
extra(Date="2026-12-12",Airline="AFR",Flight="83",From="SFO",To="CDG",**{"Gate Departure (Scheduled)":"2026-12-12T15:35"})  # upcoming
buf=io.StringIO(); w=csv.DictWriter(buf,fieldnames=H,lineterminator="\n"); w.writeheader(); w.writerows(rows)
open(sys.argv[1],"w",encoding="utf-8",newline="").write(buf.getvalue())
print(len(rows))
