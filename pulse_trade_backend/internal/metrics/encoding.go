package metrics

// ToBatch converts an ordered run of internal records into the per-table batch a
// driver writes.
//
// It is exported for driver packages that batch independently of the store's own
// writer (the SQLite driver keeps its batching loop next to its SQL so the two can
// be tested together). Because records are an internal type, drivers cannot
// construct them and can only consume what the queue hands over.
func ToBatch(records []any) Batch {
	out := make([]record, 0, len(records))
	for _, r := range records {
		if rec, ok := r.(record); ok {
			out = append(out, rec)
		}
	}
	return toBatch(out)
}
