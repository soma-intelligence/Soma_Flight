-- Runway Regulars on the airport card: the caller and their friends ranked by how many of their
-- Passport flights went through one airport (as origin or destination).
--
-- Privacy: an airport visit is Passport history, so a friend counts only when they share their
-- Passport with the caller (friendships.share_passport, off by default), both rows of the friendship
-- exist, they have not paused all sharing and their account is active, the same checks as
-- friend_passport. Only a count and the month of the latest visit leave the database: no flight,
-- date, seat or route. Canceled flights are not visits. The caller always sees their own row.
create function public.airport_regulars(p_icao text)
returns table (user_id uuid, is_me boolean, display_name text, emoji text, visits bigint, last_visit date)
language sql stable security definer set search_path = '' as $$
  with people as (
    select auth.uid() as uid, true as me
    where auth.uid() is not null
    union all
    select o.user_id, false
    from public.friendships o
    join public.friendships back on back.user_id = auth.uid() and back.friend_id = o.user_id
    left join public.friend_settings s on s.user_id = o.user_id
    left join public.profiles p on p.user_id = o.user_id
    where o.friend_id = auth.uid()
      and o.share_passport
      and not coalesce(s.sharing_paused, false)
      and coalesce(p.status, 'active') = 'active'
  )
  select pe.uid, pe.me, pr.display_name, pr.emoji, count(*),
         date_trunc('month', max(pf.date))::date
  from people pe
  join public.past_flights pf on pf.user_id = pe.uid
  left join public.profiles pr on pr.user_id = pe.uid
  where upper(p_icao) in (pf.origin_icao, pf.destination_icao)
    and pf.status <> 'canceled'
  group by pe.uid, pe.me, pr.display_name, pr.emoji
  order by count(*) desc, max(pf.date) desc, pe.uid
  limit 10;
$$;

revoke execute on function public.airport_regulars(text) from public, anon, authenticated;
grant execute on function public.airport_regulars(text) to authenticated, service_role;
