-- Airports keyed by their current ICAO code.
--
-- 20261028000002_airports_seed.sql keyed every airport by its OurAirports ident. For 74 airports the ident
-- is an old or local code and the real ICAO location indicator (OurAirports icao_code, the code flight data
-- providers send) differs: Lima SPIM is SPJC, Tashkent UTTT is UZTT, Bishkek UAFM is UCFM. A flight to the real
-- code found no airport. This renames them; supabase/seed/airports.csv is the source of the pairs.
--
-- The foreign keys onto airports(icao) (and security_throughput onto security_checkpoints) gain ON UPDATE
-- CASCADE so checkpoints, caches and favourites follow the rename; they keep ON DELETE CASCADE. Flight rows
-- keep the code the provider sent. A pair whose new code already exists is skipped, so a fresh database
-- seeded with the new codes runs this as a no-op.

alter table security_checkpoints
  drop constraint security_checkpoints_airport_icao_fkey,
  add constraint security_checkpoints_airport_icao_fkey
    foreign key (airport_icao) references airports (icao) on delete cascade on update cascade;
alter table security_throughput
  drop constraint security_throughput_airport_icao_checkpoint_id_fkey,
  add constraint security_throughput_airport_icao_checkpoint_id_fkey
    foreign key (airport_icao, checkpoint_id) references security_checkpoints (airport_icao, id)
    on delete cascade on update cascade;
alter table security_wait_cache
  drop constraint security_wait_cache_airport_icao_fkey,
  add constraint security_wait_cache_airport_icao_fkey
    foreign key (airport_icao) references airports (icao) on delete cascade on update cascade;
alter table faa_notam_cache
  drop constraint faa_notam_cache_airport_icao_fkey,
  add constraint faa_notam_cache_airport_icao_fkey
    foreign key (airport_icao) references airports (icao) on delete cascade on update cascade;
alter table favorite_airports
  drop constraint favorite_airports_airport_icao_fkey,
  add constraint favorite_airports_airport_icao_fkey
    foreign key (airport_icao) references airports (icao) on delete cascade on update cascade;

update airports a
set icao = r.new
from (values
  ('FAHT', 'FAHS'),
  ('FBFT', 'FBPM'),
  ('FGAB', 'FGAN'),
  ('FLLI', 'FLHN'),
  ('FLLS', 'FLKK'),
  ('FVBU', 'FVJN'),
  ('FVHA', 'FVRG'),
  ('GAKY', 'GAKD'),
  ('HAJK', 'HABC'),
  ('HCMW', 'HCGR'),
  ('HEBA', 'HEAX'),
  ('KPBI', 'KDJT'),
  ('LELO', 'LERJ'),
  ('MGTK', 'MGMM'),
  ('MHSC', 'MHPR'),
  ('MPHO', 'MPPA'),
  ('OPGD', 'OPGW'),
  ('ORSU', 'ORSJ'),
  ('SETM', 'SECA'),
  ('SPIM', 'SPJC'),
  ('SYGO', 'SYEC'),
  ('UAFI', 'UCFR'),
  ('UAFM', 'UCFM'),
  ('UAFO', 'UCFO'),
  ('UAFP', 'UCFK'),
  ('UTFN', 'UZFN'),
  ('UTKA', 'UZFA'),
  ('UTKF', 'UZFF'),
  ('UTNN', 'UZNN'),
  ('UTNU', 'UZNU'),
  ('UTSA', 'UZSA'),
  ('UTSB', 'UZSB'),
  ('UTSK', 'UZSK'),
  ('UTSS', 'UZSS'),
  ('UTST', 'UZST'),
  ('UTTP', 'UZTP'),
  ('UTTT', 'UZTT'),
  ('UTTZ', 'UZTZ'),
  ('VABM', 'VOBM'),
  ('VAHB', 'VOHB'),
  ('VAKJ', 'VEKO'),
  ('VARP', 'VERP'),
  ('VHST', 'VHSS'),
  ('VIAL', 'VEAB'),
  ('VICX', 'VECX'),
  ('WABP', 'WAYY'),
  ('WADT', 'WATK'),
  ('WADW', 'WATU'),
  ('WAJB', 'WAVB'),
  ('WALG', 'WAGD'),
  ('WALR', 'WAQQ'),
  ('WAMY', 'WAFY'),
  ('WAOI', 'WAGI'),
  ('WAOS', 'WAGS'),
  ('WAOW', 'WAGT'),
  ('WARJ', 'WAHH'),
  ('WARQ', 'WAHQ'),
  ('WARS', 'WAHS'),
  ('WASR', 'WAUU'),
  ('WIGM', 'WIPU'),
  ('WIOD', 'WIKT'),
  ('WION', 'WIDO'),
  ('WIPA', 'WIJJ'),
  ('WIPI', 'WIJB'),
  ('WIPK', 'WIKK'),
  ('WIPL', 'WIGG'),
  ('WIPT', 'WIEE'),
  ('WITG', 'WIML'),
  ('WPAS', 'WAPS'),
  ('WRLB', 'WAQJ'),
  ('WRLC', 'WALC'),
  ('WRLP', 'WAQL'),
  ('YSNB', 'YSNK'),
  ('ZUTC', 'ZPTC')
) as r (old, new)
where a.icao = r.old
  and not exists (select 1 from airports b where b.icao = r.new);
