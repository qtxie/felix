(** Elide unused entries
 *
 * Name binding pass 2. *)

val find_roots:
  Flx_mtypes2.sym_state_t ->
  Flx_bsym_table.t ->
  Flx_types.bid_t option ->
  Flx_btype.biface_t list ->
  unit

(* counts initialisation as use *)
val full_use_closure:
  Flx_mtypes2.sym_state_t ->
  Flx_bsym_table.t ->
  Flx_types.BidSet.t

(* conditionally count initialisation as use *)
val cal_use_closure:
  Flx_mtypes2.sym_state_t ->
  Flx_bsym_table.t ->
  bool ->
  Flx_types.BidSet.t

val copy_used:
  Flx_mtypes2.sym_state_t ->
  Flx_bsym_table.t ->
  Flx_bsym_table.t
