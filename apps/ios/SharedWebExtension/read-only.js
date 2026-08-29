(() => {
  // DOM reads must use background.js/readAuthorizedSnapshot so the lease identity,
  // full tab URL, navigation epoch, and snapshot are checked in one injected task.
  throw new Error("bound_inline_snapshot_required");
})();
