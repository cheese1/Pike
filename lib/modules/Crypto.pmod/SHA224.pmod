#pike __REAL_VERSION__
#pragma strict_types

//! SHA224 is another hash function specified by NIST, intended as a
//! replacement for @[SHA1], generating larger digests. It outputs hash
//! values of 224 bits, or 28 octets.

#if constant(Nettle) && constant(Nettle.SHA224_Info)

// NOTE: Depends on the order of INIT invocations.
inherit Nettle.SHA224_Info;
inherit .Hash;

.HashState `()() { return Nettle.SHA224_State(); }

#else
constant this_program_does_not_exist=1;
#endif
