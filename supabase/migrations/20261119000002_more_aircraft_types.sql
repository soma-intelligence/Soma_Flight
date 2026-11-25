-- Aircraft types the seed airlines fly that the list lacked (2026-11-19 catalog gaps audit): turboprops and
-- small regional types, so their flights show a type name and a plain side view. King Airs and the PC-12
-- fly mostly private and charter, so they draw as business aircraft; the rest are regional ('other').
insert into aircraft_types (icao_type, family, manufacturer, name) values
('PC12', 'bizjet', 'Pilatus', 'Pilatus PC-12'),
('B350', 'bizjet', 'Beechcraft', 'Beechcraft King Air 350'),
('BE20', 'bizjet', 'Beechcraft', 'Beechcraft King Air 200'),
('C208', 'other', 'Cessna', 'Cessna 208 Caravan'),
('DHC6', 'other', 'De Havilland Canada', 'De Havilland Canada Twin Otter'),
('B190', 'other', 'Beechcraft', 'Beechcraft 1900'),
('E120', 'other', 'Embraer', 'Embraer EMB 120 Brasilia'),
('BN2P', 'other', 'Britten-Norman', 'Britten-Norman Islander'),
('D228', 'other', 'Dornier', 'Dornier 228'),
('F50', 'other', 'Fokker', 'Fokker 50'),
('DH8B', 'other', 'De Havilland Canada', 'De Havilland Canada Dash 8-200'),
('J328', 'other', 'Dornier', 'Dornier 328JET'),
('L410', 'other', 'Let', 'Let L-410 Turbolet'),
('SW4', 'other', 'Fairchild', 'Fairchild Metro')
on conflict (icao_type) do update set family = excluded.family, manufacturer = excluded.manufacturer, name = excluded.name;
