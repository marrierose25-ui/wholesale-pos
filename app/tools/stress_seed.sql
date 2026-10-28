-- ============================================================================
-- Stress walkthrough seed: 100 days x 20 sales for the PWA tenant below.
--
-- Everything written here is tagged so app/tools/stress_cleanup.sql can remove
-- it again:
--   products  strp-01 .. strp-14      (codes STR-01 .. STR-14)
--   shifts    strsh-01 .. strsh-99
--   sales     strs-DD-II              (receipt STR-YYYYMMDD-NNNN)
--   items     stri-DD-II-L
--   cash      strcm-...
--   voids     strvr-...
--   finance   strfc-01 .. strfc-03 / strfe-01 .. strfe-08
--
-- The generated totals honour the same invariants the app enforces when
-- saving a sale: subtotal = sum(line totals), total = subtotal - discount,
-- CASH lines tender at least the total, BANK/LOAN settle exactly.
--
-- Run with:  supabase db query --linked -f app/tools/stress_seed.sql
-- ============================================================================
begin;

create temp table _str_ctx on commit drop as
select
  'b000ffca-a857-4d88-b0db-6b0cf93a72be'::uuid as tenant,
  (select id from pos_users
    where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
      and username = 'owner' and deleted_at is null) as owner_id,
  (select id from pos_users
    where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
      and username = 'demo' and deleted_at is null) as demo_id,
  (select id from shifts
    where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
      and status = 'OPEN' order by opened_at desc limit 1) as today_shift;

-- 14 wholesale names so the product report has something to rank.
insert into pos_products
  (id, customer_id, name, code, category, unit, selling_price_minor_units,
   is_active, created_at, updated_at)
select 'strp-' || lpad(v.n::text, 2, '0'), c.tenant, v.name,
       'STR-' || lpad(v.n::text, 2, '0'), v.category, v.unit, v.price, 1,
       now(), now()
from _str_ctx c,
  (values
    (1,  'Rice 25kg',       'Grocery', 'bag',    350000),
    (2,  'Cooking Oil 5L',  'Grocery', 'L',       90000),
    (3,  'Flour 25kg',      'Grocery', 'bag',    200000),
    (4,  'Sugar 50kg',      'Grocery', 'bag',    620000),
    (5,  'Tea 500g',        'Grocery', 'pack',    30000),
    (6,  'Coffee 500g',     'Grocery', 'pack',    50000),
    (7,  'Soap 250g',       'House',   'bar',      4000),
    (8,  'Detergent 1kg',   'House',   'pack',    25000),
    (9,  'Milk Powder 400g','Grocery', 'tin',     35000),
    (10, 'Salt 1kg',        'Grocery', 'pack',     2500),
    (11, 'Beans 5kg',       'Grocery', 'bag',     40000),
    (12, 'Biscuits Carton', 'Snacks',  'carton',  60000),
    (13, 'Berbere 1kg',     'Spices',  'kg',      18000),
    (14, 'Shiro 1kg',       'Spices',  'kg',      15000)
  ) v(n, name, category, unit, price)
on conflict (customer_id, id) do nothing;

-- One closed register session per past day (today reuses the live shift).
insert into shifts
  (id, customer_id, cashier_id, opening_cash_minor_units, status,
   opened_at, closed_at, origin_device_id, received_at)
select 'strsh-' || lpad(d::text, 2, '0'), c.tenant,
       case when d % 5 = 0 then c.owner_id else c.demo_id end,
       200000, 'CLOSED',
       ((current_date - d)::timestamp + interval '8 hours')
         at time zone 'Africa/Addis_Ababa',
       ((current_date - d)::timestamp + interval '19 hours 30 minutes')
         at time zone 'Africa/Addis_Ababa',
       'stress-lab', now()
from _str_ctx c, generate_series(1, 99) d
on conflict (customer_id, id) do nothing;

-- Make sure exactly one shift is open (the newest), then use it for today.
insert into shifts
  (id, customer_id, cashier_id, opening_cash_minor_units, status,
   opened_at, origin_device_id)
select 'strsh-00', c.tenant, c.owner_id, 300000, 'OPEN',
       (current_date::timestamp + interval '8 hours')
         at time zone 'Africa/Addis_Ababa', 'stress-lab'
from _str_ctx c where c.today_shift is null;

update shifts s
set status = 'CLOSED',
    closed_at = coalesce(s.closed_at, s.opened_at + interval '10 hours')
where s.customer_id = (select tenant from _str_ctx)
  and s.status = 'OPEN'
  and s.id <> (select id from shifts
               where customer_id = (select tenant from _str_ctx)
                 and status = 'OPEN'
               order by opened_at desc limit 1);

update _str_ctx
set today_shift = (select id from shifts
                   where customer_id = _str_ctx.tenant and status = 'OPEN'
                   order by opened_at desc limit 1);

-- Line-level detail (kept in a temp table so the sale header can be derived
-- from exactly the same arithmetic).
create temp table _str_items on commit drop as
select
  d, i, l,
  'stri-' || lpad(d::text, 2, '0') || '-' || lpad(i::text, 2, '0') || '-' || l::text as item_id,
  'strs-' || lpad(d::text, 2, '0') || '-' || lpad(i::text, 2, '0') as sale_id,
  p.id as product_id, p.name, p.unit, p.price, q.qty,
  p.price * q.qty as base,
  case when (d * 13 + i * 7 + l * 3) % 9 = 0
       then (p.price * q.qty) * 3 / 100 else 0 end as disc
from generate_series(0, 99) d
cross join generate_series(1, 20) i
cross join lateral generate_series(1, 1 + ((d * 7 + i * 3) % 4)) l
cross join lateral (select 1 + ((d * 13 + i * 7 + l * 3) % 4) as qty) q
cross join lateral (
  select id, name, unit, price from (
    select id, name, unit, selling_price_minor_units as price,
           row_number() over (order by id) as rn
    from pos_products
    where customer_id = (select tenant from _str_ctx)
      and id like 'strp-%'
  ) x
  where rn = ((d * 11 + i * 5 + l * 3) % 14) + 1
) p;

create temp table _str_sales on commit drop as
select
  sale_id,
  min(d) as d, min(i) as i,
  sum(base - disc) as subtotal,
  case when (min(d) + min(i)) % 10 = 0
       then sum(base - disc) * 2 / 100 else 0 end as discount
from _str_items
group by sale_id;

insert into sales
  (id, customer_id, receipt_number, cashier_id, device_id, shift_id,
   customer_name, payment_method, subtotal_minor_units, discount_minor_units,
   total_minor_units, amount_paid_minor_units, change_minor_units, status,
   created_at, origin_device_id, received_at)
select
  sa.sale_id, c.tenant,
  'STR-' || to_char(current_date - sa.d, 'YYYYMMDD') || '-' || lpad(sa.i::text, 4, '0'),
  case when sa.d % 7 = 0 then c.owner_id else c.demo_id end,
  'stress-lab',
  coalesce(case when sa.d = 0 then c.today_shift end,
           'strsh-' || lpad(sa.d::text, 2, '0')),
  (array['Abebe Tesfaye','Tigist Alemu','Hana Girma','Dawit Bekele',
         'Selam Mekonnen','Meron Assefa','Yonas Kebede','Sara Haile',
         'Kalkidan Tesfaye','Bekele Wolde','Meseret Abebe','Fikru Tadesse'])
    [(sa.d + sa.i) % 12 + 1],
  pay.method,
  sa.subtotal, sa.discount, sa.subtotal - sa.discount,
  case when pay.method = 'CASH'
       then sa.subtotal - sa.discount + pay.extra
       else sa.subtotal - sa.discount end,
  case when pay.method = 'CASH' then pay.extra else 0 end,
  'COMPLETED',
  ((current_date - sa.d)::timestamp + interval '8 hours'
     + sa.i * interval '33 minutes') at time zone 'Africa/Addis_Ababa',
  'stress-lab', now()
from _str_sales sa
cross join lateral (select tenant, owner_id, demo_id, today_shift from _str_ctx) c
cross join lateral (
  select case when (sa.d * 7 + sa.i) % 10 < 6 then 'CASH'
              when (sa.d * 7 + sa.i) % 10 < 9 then 'BANK'
              else 'LOAN' end as method,
         case when (sa.d + sa.i) % 3 = 0 then 5000 else 1500 end as extra
) pay;

insert into sale_items
  (id, customer_id, sale_id, product_id, product_name_snapshot,
   unit_price_snapshot_minor_units, quantity_text, billing_quantity_milliunits,
   line_discount_minor_units, line_total_minor_units, origin_device_id,
   received_at)
select si.item_id, c.tenant, si.sale_id, si.product_id, si.name, si.price,
       si.qty || ' ' || si.unit, si.qty * 1000, si.disc, si.base - si.disc,
       'stress-lab', now()
from _str_items si
cross join lateral (select tenant from _str_ctx) c;

-- Cash ledger activity on the generated sessions.
insert into cash_movements
  (id, customer_id, shift_id, type, amount_minor_units, reason, created_at,
   user_id, origin_device_id, received_at, photo)
select
  'strcm-d' || lpad(d::text, 2, '0'),
  c.tenant,
  'strsh-' || lpad(d::text, 2, '0'),
  'DEPOSIT', 50000, 'Owner top-up for change',
  ((current_date - d)::timestamp + interval '10 hours')
    at time zone 'Africa/Addis_Ababa',
  c.demo_id, 'stress-lab', now(), null
from _str_ctx c, generate_series(1, 99) d where d % 3 = 0;

insert into cash_movements
  (id, customer_id, shift_id, type, amount_minor_units, reason, created_at,
   user_id, origin_device_id, received_at, photo)
select
  'strcm-w' || lpad(d::text, 2, '0'),
  c.tenant,
  'strsh-' || lpad(d::text, 2, '0'),
  'WITHDRAWAL', 30000, 'Deposit to bank',
  ((current_date - d)::timestamp + interval '15 hours')
    at time zone 'Africa/Addis_Ababa',
  c.demo_id, 'stress-lab', now(), null
from _str_ctx c, generate_series(1, 99) d where d % 4 = 0;

insert into cash_movements
  (id, customer_id, shift_id, type, amount_minor_units, reason, created_at,
   user_id, origin_device_id, received_at, photo)
select
  'strcm-e' || lpad(d::text, 2, '0'),
  c.tenant,
  'strsh-' || lpad(d::text, 2, '0'),
  'EXPENSE', 12000, 'Fuel and transport',
  ((current_date - d)::timestamp + interval '16 hours')
    at time zone 'Africa/Addis_Ababa',
  c.demo_id, 'stress-lab', now(), null
from _str_ctx c, generate_series(1, 99) d where d % 5 = 0;

-- Today's live session gets a movement too, so the register ledger is not empty.
insert into cash_movements
  (id, customer_id, shift_id, type, amount_minor_units, reason, created_at,
   user_id, origin_device_id, received_at, photo)
select 'strcm-today', c.tenant, c.today_shift, 'DEPOSIT', 200000,
       'Owner top-up for change',
       (current_date::timestamp + interval '9 hours')
         at time zone 'Africa/Addis_Ababa',
       c.owner_id, 'stress-lab', now(),
       'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
from _str_ctx c where c.today_shift is not null;

-- Voids: eleven owner voids spread across the history plus two today.
update sales s
set status = 'VOIDED',
    void_reason = (array['Customer returned damaged goods',
                        'Wrong price entered',
                        'Goods loaded twice by mistake'])[(s.subtotal_minor_units % 3)::int + 1],
    voided_at = s.created_at + interval '45 minutes',
    voided_by = c.owner_id,
    voided_shift_id = s.shift_id
from _str_ctx c
where s.customer_id = c.tenant
  and s.id in (
    select 'strs-' || lpad(d::text, 2, '0') || '-04'
    from generate_series(3, 93, 9) d
    union all select 'strs-00-07'
    union all select 'strs-00-15'
  );

-- Cashier void requests: one still waiting for the owner, two approved,
-- one rejected.
insert into void_requests
  (id, customer_id, sale_id, requested_by, reason, status, created_at,
   decided_by, decided_at, origin_device_id, received_at)
values
  ('strvr-01', 'b000ffca-a857-4d88-b0db-6b0cf93a72be', 'strs-00-05',
   (select demo_id from _str_ctx), 'Customer changed their mind', 'PENDING',
   (current_date::timestamp + interval '12 hours')
     at time zone 'Africa/Addis_Ababa', null, null, 'stress-lab', now()),
  ('strvr-02', 'b000ffca-a857-4d88-b0db-6b0cf93a72be', 'strs-00-09',
   (select demo_id from _str_ctx), 'Wrong item picked', 'APPROVED',
   (current_date::timestamp + interval '13 hours')
     at time zone 'Africa/Addis_Ababa',
   (select owner_id from _str_ctx),
   (current_date::timestamp + interval '13 hours 10 minutes')
     at time zone 'Africa/Addis_Ababa', 'stress-lab', now()),
  ('strvr-03', 'b000ffca-a857-4d88-b0db-6b0cf93a72be', 'strs-00-11',
   (select demo_id from _str_ctx), 'Suspected counterfeit note', 'REJECTED',
   (current_date::timestamp + interval '14 hours')
     at time zone 'Africa/Addis_Ababa',
   (select owner_id from _str_ctx),
   (current_date::timestamp + interval '14 hours 20 minutes')
     at time zone 'Africa/Addis_Ababa', 'stress-lab', now()),
  ('strvr-04', 'b000ffca-a857-4d88-b0db-6b0cf93a72be', 'strs-10-05',
   (select demo_id from _str_ctx), 'Goods damaged in transit', 'APPROVED',
   ((current_date - 10)::timestamp + interval '11 hours')
     at time zone 'Africa/Addis_Ababa',
   (select owner_id from _str_ctx),
   ((current_date - 10)::timestamp + interval '11 hours 30 minutes')
     at time zone 'Africa/Addis_Ababa', 'stress-lab', now());

update sales s
set status = 'VOIDED',
    void_reason = 'Approved cashier void request',
    voided_at = s.created_at + interval '1 hour',
    voided_by = c.owner_id,
    voided_shift_id = s.shift_id
from _str_ctx c
where s.customer_id = c.tenant and s.id in ('strs-00-09', 'strs-10-05');

-- Money tracking: three people and eight entries (some settled).
insert into pos_finance_categories
  (id, customer_id, name, created_at, updated_at)
select 'strfc-01', c.tenant, 'Supplier - Abebe', now(), now() from _str_ctx c
union all
select 'strfc-02', c.tenant, 'Transport', now(), now() from _str_ctx c
union all
select 'strfc-03', c.tenant, 'Shop Rent', now(), now() from _str_ctx c;

insert into pos_finance_entries
  (id, customer_id, category_id, source, amount_minor_units, description,
   status, entry_date, created_at, created_by, completed_at, completed_by,
   updated_at, payment_method)
select
  'strfe-' || lpad(e.n::text, 2, '0'), c.tenant, e.cat::text, e.src, e.amount,
  e.descr,
  case when e.n % 3 = 0 then 'COMPLETED' else 'PENDING' end,
  ((current_date - e.days_ago)::timestamp + interval '10 hours')
    at time zone 'Africa/Addis_Ababa',
  ((current_date - e.days_ago)::timestamp + interval '10 hours')
    at time zone 'Africa/Addis_Ababa',
  c.owner_id,
  case when e.n % 3 = 0
       then ((current_date - e.days_ago)::timestamp + interval '12 hours')
              at time zone 'Africa/Addis_Ababa' end,
  case when e.n % 3 = 0 then c.owner_id end,
  now(),
  case when e.n % 2 = 0 then 'CASH' else 'BANK' end
from _str_ctx c,
  (values
    (1, 'strfc-01', 'Abebe Tesfaye', 450000, 'Rice and flour restock', 2),
    (2, 'strfc-01', 'Abebe Tesfaye', 180000, 'Sugar balance', 9),
    (3, 'strfc-02', 'Blue Taxi',       25000, 'Delivery to Merkato', 1),
    (4, 'strfc-02', 'Blue Taxi',       18000, 'Delivery to Bole', 5),
    (5, 'strfc-03', 'Landlord',      1200000, 'Shop rent this month', 12),
    (6, 'strfc-01', 'Abebe Tesfaye', 320000, 'Oil cartons', 16),
    (7, 'strfc-02', 'Minibus',          9000, 'Staff transport', 21),
    (8, 'strfc-03', 'Landlord',       600000, 'Rent balance', 30)
  ) e(n, cat, src, amount, descr, days_ago);

-- Fold every generated sale and movement back into each session's figures.
with calc as (
  select s.id,
    s.opening_cash_minor_units
    + coalesce((select sum(total_minor_units) from sales
                where shift_id = s.id and status = 'COMPLETED'
                  and payment_method = 'CASH'), 0)
    + coalesce((select sum(case when type = 'DEPOSIT'
                               then amount_minor_units
                               else -amount_minor_units end)
                from cash_movements where shift_id = s.id), 0)
    - coalesce((select sum(total_minor_units) from sales
                where status = 'VOIDED' and payment_method = 'CASH'
                  and voided_shift_id = s.id and shift_id <> s.id), 0) as expected
  from shifts s
  where s.customer_id = (select tenant from _str_ctx)
)
update shifts t
set expected_cash_minor_units = c.expected,
    closing_cash_minor_units = case when t.status = 'CLOSED'
                                    then c.expected
                                    else t.closing_cash_minor_units end
from calc c
where t.id = c.id;

commit;
