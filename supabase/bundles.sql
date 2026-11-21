-- 享尼義賣：組合優惠（在 Supabase 的 SQL Editor 貼上整段後按 Run；需先執行過 shop.sql。可重複執行）
-- 購物車湊成組合就自動折價。一件商品只算進一個組合，系統自動挑最省錢的配法。

-- ========== 1. 組合資料表 ==========
-- slots：組合裡的每一格放哪些商品可以算數，例如 [["si_stat0:0"],["si_stat2:0"]]
--        同一格有多個代號 = 任選其一（例如排汗或棉質 T 恤）
create table if not exists public.bundles (
  id      text primary key,
  emoji   text not null default '🎁',
  name    text not null,
  name_en text not null,
  price   int  not null check (price > 0),     -- 組合價
  slots   jsonb not null,
  active  boolean not null default true,       -- false = 暫停這個組合
  sort    int  not null default 0
);
insert into public.bundles (id, emoji, name, name_en, price, slots, sort) values
  ('postcard3', '📮', '明信片 3 入',   'Postcards ×3',        200, '[["si_stat0:0"],["si_stat0:0"],["si_stat0:0"]]', 1),
  ('stationery','✏️', '文具小物組',    'Stationery set',      180, '[["si_stat0:0"],["si_stat1:0"],["si_stat2:0"]]', 2),
  ('cheer',     '🐯', '享尼應援組',    'ShiNepal fan set',    620, '[["si_apparel0:0","si_apparel1:0"],["si_bags0:1"]]', 3),
  ('travel',    '🧳', '旅行收納組',    'Travel pouch set',    499, '[["si_bags5:0"],["si_bags6:0"],["si_stat4:0"]]', 4),
  ('winter',    '🧣', '尼泊爾暖冬組',  'Nepal winter set',    760, '[["si_acc1:0"],["si_acc2:0"]]', 5)
on conflict (id) do nothing;

alter table public.bundles enable row level security;
drop policy if exists "read bundles" on public.bundles;
create policy "read bundles" on public.bundles for select to anon using (true);
grant select on public.bundles to anon;

alter table public.orders add column if not exists discount int not null default 0;
alter table public.orders add column if not exists bundles  jsonb;

-- ========== 2. 計算最省錢的組合配法 ==========
-- q：購物車數量 {"sku": 數量}；pr：單價 {"sku": 價格}；bs：組合陣列；i：從第幾個組合開始試
create or replace function public.bundle_best(q jsonb, pr jsonb, bs jsonb, i int default 0)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  b jsonb; best jsonb; rest jsonb; q2 jsonb; slot jsonb; alt text; pick text;
  k int := 0; total_save int := 0; worth int; cand int;
begin
  if bs is null or i >= jsonb_array_length(bs) then
    return jsonb_build_object('save', 0, 'apps', '[]'::jsonb);
  end if;
  b := bs->i;
  best := bundle_best(q, pr, bs, i + 1);           -- 這個組合用 0 次
  q2 := q;
  loop
    -- 再湊一組：每一格挑「有貨、價格最高」的商品
    worth := 0;
    for slot in select * from jsonb_array_elements(b->'slots') loop
      pick := null;
      for alt in select jsonb_array_elements_text(slot) loop
        if coalesce((q2->>alt)::int, 0) > 0
           and (pick is null or coalesce((pr->>alt)::int, 0) > coalesce((pr->>pick)::int, 0)) then
          pick := alt;
        end if;
      end loop;
      if pick is null then return best; end if;   -- 湊不齊了
      q2 := jsonb_set(q2, array[pick], to_jsonb((q2->>pick)::int - 1));
      worth := worth + coalesce((pr->>pick)::int, 0);
    end loop;
    if worth <= (b->>'price')::int then return best; end if;   -- 沒有比較便宜就不算
    k := k + 1;
    total_save := total_save + worth - (b->>'price')::int;
    rest := bundle_best(q2, pr, bs, i + 1);
    cand := total_save + (rest->>'save')::int;
    if cand > (best->>'save')::int then
      best := jsonb_build_object('save', cand,
        'apps', jsonb_build_array(jsonb_build_object('id', b->>'id', 'name', b->>'name', 'times', k, 'save', total_save)) || (rest->'apps'));
    end if;
    if k >= 50 then return best; end if;
  end loop;
end;
$$;

-- ========== 3. 下單時套用組合優惠（取代 shop.sql 的 place_order） ==========
create or replace function public.place_order(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s        shop_settings;
  it       jsonb;
  pr       products;
  lines    jsonb := '[]'::jsonb;
  qtys     jsonb := '{}'::jsonb;
  prices   jsonb := '{}'::jsonb;
  bs       jsonb;
  bb       jsonb;
  k        text;
  q        int;
  sub      int := 0;
  disc     int := 0;
  net      int;
  ship     int;
  tier     reward_tiers;
  v_name   text := btrim(coalesce(p->>'name',''));
  v_phone  text := regexp_replace(coalesce(p->>'phone',''), '[^0-9]', '', 'g');
  v_email  text := lower(btrim(coalesce(p->>'email','')));
  v_zip    text := left(btrim(coalesce(p->>'zip','')), 6);
  v_addr   text := btrim(coalesce(p->>'address',''));
  v_note   text := left(btrim(coalesce(p->>'note','')), 300);
  v_choice text := left(btrim(coalesce(p->>'reward_choice','')), 100);
  v_sizes  text := left(btrim(coalesce(p->>'sizes','')), 100);
  needs_size boolean := false;
  v_no     text;
  v_pay_by timestamptz;
begin
  select * into s from shop_settings where id = 1;
  if not s.orders_open then raise exception 'ORDERS_CLOSED'; end if;

  if char_length(v_name) not between 1 and 40 then raise exception 'BAD_NAME'; end if;
  if v_phone !~ '^09[0-9]{8}$' then raise exception 'BAD_PHONE'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 120 then raise exception 'BAD_EMAIL'; end if;
  if char_length(v_addr) not between 6 and 200 then raise exception 'BAD_ADDRESS'; end if;
  if (p->>'agree') is distinct from 'true' then raise exception 'NO_CONSENT'; end if;

  if (select count(*) from orders where phone = v_phone and status = '待付款'
        and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'TOO_MANY_ORDERS';
  end if;

  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') not between 1 and 30 then
    raise exception 'BAD_ITEMS';
  end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    k := it->>'sku';
    q := (it->>'qty')::int;
    if k is null or q is null or q < 1 or q > 99 then raise exception 'BAD_ITEMS'; end if;
    qtys := jsonb_set(qtys, array[k], to_jsonb(coalesce((qtys->>k)::int, 0) + q));
  end loop;

  for k, q in select key, value::int from jsonb_each_text(qtys) order by key loop
    select * into pr from products where sku = k for update;
    if not found or not pr.active then raise exception 'UNAVAILABLE:%', k; end if;
    if pr.stock is not null and pr.stock < q then raise exception 'OUT_OF_STOCK:%:%', k, pr.stock; end if;
    if q > 99 then raise exception 'BAD_ITEMS'; end if;
    update products set stock = stock - q where sku = k and stock is not null;
    if k like 'si_apparel%' then needs_size := true; end if;
    sub := sub + pr.price * q;
    prices := jsonb_set(prices, array[k], to_jsonb(pr.price));
    lines := lines || jsonb_build_object('sku', pr.sku, 'name', pr.name, 'price', pr.price, 'qty', q);
  end loop;

  if needs_size and v_sizes = '' then raise exception 'NEED_SIZES'; end if;

  -- 組合優惠
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price', price, 'slots', slots) order by sort, id), '[]'::jsonb)
    into bs from bundles where active;
  bb := bundle_best(qtys, prices, bs, 0);
  disc := least((bb->>'save')::int, sub);
  net := sub - disc;

  ship := case when s.free_shipping_over is not null and net >= s.free_shipping_over then 0 else s.shipping_fee end;
  select * into tier from reward_tiers where amount <= net order by amount desc limit 1;
  v_no := 'SN' || to_char(now() at time zone 'Asia/Taipei', 'YYMMDD') || '-' || lpad((nextval('order_seq') % 100000)::text, 5, '0');
  v_pay_by := (date_trunc('day', now() at time zone 'Asia/Taipei') + make_interval(days => s.pay_days + 1)) at time zone 'Asia/Taipei';

  insert into orders (order_no, buyer_name, phone, email, zip, address, note, items, subtotal, discount, bundles, shipping, total,
                      reward_amount, reward_perks, reward_choice, sizes, pay_by)
  values (v_no, v_name, v_phone, v_email, nullif(v_zip,''), v_addr, nullif(v_note,''), lines, sub, disc,
          case when disc > 0 then bb->'apps' end, ship, net + ship,
          tier.amount, tier.perks, case when tier.amount is null then null else nullif(v_choice,'') end,
          case when needs_size then v_sizes end, v_pay_by);

  return jsonb_build_object(
    'order_no', v_no, 'items', lines, 'subtotal', sub, 'discount', disc, 'bundles', case when disc > 0 then bb->'apps' end,
    'shipping', ship, 'total', net + ship,
    'reward_amount', tier.amount, 'reward_perks', tier.perks, 'pay_by', v_pay_by,
    'bank', jsonb_build_object('name', s.bank_name, 'code', s.bank_code, 'account', s.bank_account, 'holder', s.account_name));
end;
$$;

-- ========== 4. 訂單查詢也顯示組合優惠 ==========
create or replace function public.get_order(p_order_no text, p_phone text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'order_no', o.order_no, 'created_at', o.created_at, 'status', o.status, 'items', o.items,
    'subtotal', o.subtotal, 'discount', o.discount, 'bundles', o.bundles, 'shipping', o.shipping, 'total', o.total,
    'reward_amount', o.reward_amount, 'reward_perks', o.reward_perks, 'reward_choice', o.reward_choice, 'sizes', o.sizes,
    'pay_by', o.pay_by, 'transfer_reported', o.transfer_reported_at is not null, 'tracking_no', o.tracking_no,
    'bank', jsonb_build_object('name', s.bank_name, 'code', s.bank_code, 'account', s.bank_account, 'holder', s.account_name))
  from orders o cross join shop_settings s
  where o.order_no = upper(btrim(p_order_no))
    and o.phone = regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g')
    and s.id = 1;
$$;

revoke all on function public.place_order(jsonb) from public;
revoke all on function public.get_order(text, text) from public;
revoke all on function public.bundle_best(jsonb, jsonb, jsonb, int) from public, anon, authenticated;
grant execute on function public.place_order(jsonb) to anon;
grant execute on function public.get_order(text, text) to anon;
