// Build-time LeakSanitizer opt-out (fleet policy): leaks are not the bug class this target is
// fuzzed for. ASan's memory-error checks and UBSan stay on and halting. Linked into every
// ASan-built binary by mayhem/build.sh.
extern "C" int __lsan_is_turned_off() { return 1; }
