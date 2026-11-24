# Warehouse Guide — Wholesale POS

## What Is a Picklist?

A picklist is a structured request to receive goods from a supplier. It tracks what you ordered, what quantity, and what actually arrived.

Picklists have four statuses:

| Status | Meaning |
| -------- | --------- |
| `PENDING` | Created but no items taken yet |
| `PARTIAL` | Some items fully received |
| `COMPLETED` | All line items matched or exceeded requested qty |
| `CANCELLED` | Abandoned before completion |

Status derives automatically from item quantities — you don't set it manually.

## Creating a Picklist

1. Tap **Warehouse** → **+ New Picklist**.
2. Enter a name (e.g., `Order #2024-087`).
3. Add items: select a product, enter the expected quantity.
4. Save. The picklist opens immediately in edit mode.

## Managing Items on a Picklist

- **Add line** — choose product + quantity.
- **Edit quantity** — tap the value cell; use the stepper or type directly.
- **Remove line** — swipe left or tap 🗑 on the row.
- **Mark received** — tap the ✓ checkbox on each line. The `taken_qty` updates; the picklist recalculates status.

> **Auto-complete:** When every line reaches `taken_qty >= requested_qty`, status flips to `COMPLETED`.

## Customer & Supplier Directory

Under **Warehouse → Customers** and **Warehouse → Suppliers**, manage contact records linked to picklists. Each customer/supplier has a name, phone, and optional address. They are local-only (not synced to cloud) to keep the directory private to your device.

## Importing Stock from Suppliers

Picklists double as receiving documents. After a supplier delivers:

1. Open the corresponding picklist.
2. Verify each line against the invoice.
3. Tap ✓ on confirmed lines.
4. Adjust quantities if the delivery was short or over.
5. The app logs the final state in audit for accountability.

## Reporting

**Warehouse → Reports** shows:

- Pending picklists awaiting fulfillment.
- Completion rate by supplier.
- Products frequently reordered (reorder suggestion).

## Offline Behavior

Picklist edits work fully offline. When you reconnect, changes push through the outbox. Conflicts are resolved server-side using last-write-wins semantics; expect to review any overlapping edits from another device.
