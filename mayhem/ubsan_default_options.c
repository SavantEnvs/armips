/*
 * mayhem/ubsan_default_options.c — make the UBSan hit in the fuzz target a CRASH.
 *
 * The armips CLI returns exit status 1 for any ordinary assembly error, and a halting UBSan
 * (-fno-sanitize-recover) also exits 1 on Linux — so a sanitizer hit is indistinguishable from a
 * rejected input, and neither AFL nor Mayhem records a defect. Overriding the runtime's weak
 * __ubsan_default_options turns it into SIGABRT while keeping the diagnostic on stderr, which is
 * how the original mayhemheroes image surfaced the signed-integer-overflow in stringToInt
 * (Util/Util.cpp:100) as CWE-190. Linked into the fuzz target by mayhem/build.sh only.
 */
const char *__ubsan_default_options(void)
{
	return "halt_on_error=1:abort_on_error=1:print_stacktrace=1";
}
