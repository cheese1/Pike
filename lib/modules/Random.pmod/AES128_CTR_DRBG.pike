#pike __REAL_VERSION__
#pragma strict_types

//! Implements NIST SP800-90Ar1 pseudo random number generator
//! CTR_DRBG using AES-128.
//!
//! https://csrc.nist.gov/publications/detail/sp/800-90a/rev-1/final

inherit Builtin.RandomInterface;
inherit Nettle.AES128_CTR_DRBG;

#define SEEDLEN 32/* keylen + ctrlen */

//! Instantiate a random generator without derivation function, with
//! the given initial entropy and personalization.
protected void create(string(8bit) entropy, void|string(8bit) personalization)
{
  if( personalization )
  {
    if(sizeof(personalization)>SEEDLEN)
      error("Personalization longer than seed length (%d)\n", SEEDLEN);
    personalization = sprintf("%-*'\0's", SEEDLEN, personalization);
    entropy ^= personalization;
  }
  ::reseed(entropy);
}
