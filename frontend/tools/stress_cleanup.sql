-- Removes everything app/tools/stress_seed.sql created, newest concerns first.
-- Run with:  supabase db query --linked -f app/tools/stress_cleanup.sql
begin;

delete from void_requests
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strvr-%';

delete from sale_items
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'stri-%';

delete from sales
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strs-%';

delete from cash_movements
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strcm-%';

delete from shifts
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strsh-%';

delete from pos_products
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strp-%';

delete from pos_finance_entries
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strfe-%';

delete from pos_finance_categories
where customer_id = 'b000ffca-a857-4d88-b0db-6b0cf93a72be'
  and id like 'strfc-%';

commit;
