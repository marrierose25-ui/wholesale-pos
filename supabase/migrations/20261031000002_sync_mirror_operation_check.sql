-- ---------------------------------------------------------------------------
-- sync_mirror.operation was a free-text column: the gateway upper-cases what a
-- device sends, but nothing stopped a row staged with any other word. Staging
-- is the gate every device write passes through, so the vocabulary is pinned
-- here (`pos_sync_apply` only understands UPSERT and DELETE; anything else
-- falls through to its "unknown operation" handling long after the row landed).
-- ---------------------------------------------------------------------------

ALTER TABLE public.sync_mirror
  ADD CONSTRAINT sync_mirror_operation_check
  CHECK (operation IN ('UPSERT', 'DELETE'));
