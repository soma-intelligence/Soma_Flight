-- Business jets: a 'bizjet' family for the aircraft types, so private flights draw as a business jet.
alter table aircraft_types drop constraint if exists aircraft_types_family_check;
alter table aircraft_types add constraint aircraft_types_family_check check (family in (
  'a220', 'a320', 'a330', 'a350', 'a380', 'b737', 'b737max', 'b747', 'b757', 'b767', 'b777', 'b787',
  'ejet', 'crj', 'atr', 'bizjet', 'other'));

update aircraft_types set family = 'bizjet' where icao_type = 'E35L';

insert into aircraft_types (icao_type, family, manufacturer, name) values
('GLF4', 'bizjet', 'Gulfstream', 'Gulfstream IV'),
('GLF5', 'bizjet', 'Gulfstream', 'Gulfstream G550'),
('GLF6', 'bizjet', 'Gulfstream', 'Gulfstream G650'),
('G280', 'bizjet', 'Gulfstream', 'Gulfstream G280'),
('GA5C', 'bizjet', 'Gulfstream', 'Gulfstream G500'),
('GA6C', 'bizjet', 'Gulfstream', 'Gulfstream G600'),
('GA7C', 'bizjet', 'Gulfstream', 'Gulfstream G700'),
('GA8C', 'bizjet', 'Gulfstream', 'Gulfstream G800'),
('GLEX', 'bizjet', 'Bombardier', 'Bombardier Global 6000'),
('GL5T', 'bizjet', 'Bombardier', 'Bombardier Global 5000'),
('GL7T', 'bizjet', 'Bombardier', 'Bombardier Global 7500'),
('CL30', 'bizjet', 'Bombardier', 'Bombardier Challenger 300'),
('CL35', 'bizjet', 'Bombardier', 'Bombardier Challenger 350'),
('CL60', 'bizjet', 'Bombardier', 'Bombardier Challenger 600'),
('LJ45', 'bizjet', 'Bombardier', 'Learjet 45'),
('LJ75', 'bizjet', 'Bombardier', 'Learjet 75'),
('FA7X', 'bizjet', 'Dassault', 'Dassault Falcon 7X'),
('FA8X', 'bizjet', 'Dassault', 'Dassault Falcon 8X'),
('FA6X', 'bizjet', 'Dassault', 'Dassault Falcon 6X'),
('F900', 'bizjet', 'Dassault', 'Dassault Falcon 900'),
('F2TH', 'bizjet', 'Dassault', 'Dassault Falcon 2000'),
('FA50', 'bizjet', 'Dassault', 'Dassault Falcon 50'),
('C510', 'bizjet', 'Cessna', 'Cessna Citation Mustang'),
('C525', 'bizjet', 'Cessna', 'Cessna Citation CJ1'),
('C25A', 'bizjet', 'Cessna', 'Cessna Citation CJ2'),
('C25B', 'bizjet', 'Cessna', 'Cessna Citation CJ3'),
('C25C', 'bizjet', 'Cessna', 'Cessna Citation CJ4'),
('C560', 'bizjet', 'Cessna', 'Cessna Citation V'),
('C56X', 'bizjet', 'Cessna', 'Cessna Citation Excel'),
('C680', 'bizjet', 'Cessna', 'Cessna Citation Sovereign'),
('C68A', 'bizjet', 'Cessna', 'Cessna Citation Latitude'),
('C700', 'bizjet', 'Cessna', 'Cessna Citation Longitude'),
('C750', 'bizjet', 'Cessna', 'Cessna Citation X'),
('E50P', 'bizjet', 'Embraer', 'Embraer Phenom 100'),
('E55P', 'bizjet', 'Embraer', 'Embraer Phenom 300'),
('E545', 'bizjet', 'Embraer', 'Embraer Praetor 500'),
('E550', 'bizjet', 'Embraer', 'Embraer Praetor 600'),
('PC24', 'bizjet', 'Pilatus', 'Pilatus PC-24'),
('HDJT', 'bizjet', 'Honda', 'HondaJet'),
('H25B', 'bizjet', 'Hawker', 'Hawker 800'),
('BE40', 'bizjet', 'Hawker', 'Hawker 400'),
('SF50', 'bizjet', 'Cirrus', 'Cirrus Vision Jet')
on conflict (icao_type) do update set family = excluded.family, manufacturer = excluded.manufacturer, name = excluded.name;
