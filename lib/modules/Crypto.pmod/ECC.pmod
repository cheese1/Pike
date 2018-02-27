#pike __REAL_VERSION__
#require constant(Nettle.ECC_Curve)

//! Elliptic Curve Cipher Constants.
//!
//! This module contains constants used with elliptic curve algorithms.


// The module dumper has problems with the overloaded ECDSA class,
// so inhibit dumping of this module for now.
constant dont_dump_module = 1;

//! The definition of an elliptic curve.
//!
//! Objects of this class are typically not created by the user.
//!
//! @seealso
//!   @[SECP_192R1], @[SECP_224R1], @[SECP_256R1], @[SECP_384R1], @[SECP_521R1]
class Curve {
  inherit Nettle.ECC_Curve;

  string(7bit) jose_name()
  {
    return ([
      "SECP_256R1":"P-256",
      "SECP_384R1":"P-384",
      "SECP_521R1":"P-521",
    ])[name()];
  }

#define BitString Standards.ASN1.Types.BitString
#define Identifier Standards.ASN1.Types.Identifier
#define Integer Standards.ASN1.Types.Integer
#define Object Standards.ASN1.Types.Object
#define Sequence Standards.ASN1.Types.Sequence

  //! Returns the PKCS-1 elliptic curve identifier for the curve.
  //! cf RFC 5480 2.1.1.
  Identifier pkcs_named_curve_id()
  {
    switch(name()) {
    case "SECP_192R1":
      return Standards.PKCS.Identifiers.ecc_secp192r1_id;
    case "SECP_224R1":
      return Standards.PKCS.Identifiers.ecc_secp224r1_id;
    case "SECP_256R1":
      return Standards.PKCS.Identifiers.ecc_secp256r1_id;
    case "SECP_384R1":
      return Standards.PKCS.Identifiers.ecc_secp384r1_id;
    case "SECP_521R1":
      return Standards.PKCS.Identifiers.ecc_secp521r1_id;
    }
    return 0;
  }

  //! Returns the PKCS-1 elliptic curve parameters for the curve.
  //! cf RFC 5480 2.1.1.
  Identifier pkcs_ec_parameters()
  {
    return pkcs_named_curve_id();
  }

  //! Returns the AlgorithmIdentifier as defined in RFC5480 section 2.
  Sequence pkcs_algorithm_identifier()
  {
    return
      Sequence( ({ Standards.PKCS.Identifiers.ec_id,
		   pkcs_ec_parameters(),
		}) );
  }

  //! Elliptic Curve Digital Signing Algorithm
  //!
  class ECDSA
  {
    //! @ignore
    inherit ::this_program;
    //! @endignore

    //! @decl inherit ECC_Curve::ECDSA;

    //! Return the curve.
    Curve get_curve()
    {
      return Curve::this;
    }

    //! Return the curve size in bits.
    int size()
    {
      return Curve::size();
    }

    //! Return the size of the private key in bits.
    int(0..) key_size()
    {
      return Curve::size();
    }

    //! Set the private key.
    //!
    //! @note
    //!   Throws errors if the key isn't valid for the curve.
    this_program set_private_key(object(Gmp.mpz)|int k)
    {
      ::set_private_key(k);
      return this;
    }

    //! Change to the selected point on the curve as public key.
    //!
    //! @note
    //!   Throws errors if the point isn't on the curve.
    this_program set_public_key(object(Gmp.mpz)|int x, object(Gmp.mpz)|int y)
    {
      ::set_public_key(x, y);
      return this;
    }

    //! Change to the selected point on the curve as public key.
    //!
    //! @param key
    //!   The public key encoded according to ANSI x9.62 4.3.6.
    //!
    //! @note
    //!   Throws errors if the point isn't on the curve.
    variant this_program set_public_key(string(8bit) key)
    {
      int sz = (size() + 7)>>3;
      if ((sizeof(key) != 1 + 2*sz) || (key[0] != 4)) {
	error("Invalid public key for curve.\n");
      }

      object(Gmp.mpz)|int x;
      object(Gmp.mpz)|int y;

      sscanf(key, "%*c%" + sz + "c%" + sz + "c", x, y);

      ::set_public_key(x, y);
      return this;
    }

    //! Compares the public key in this object with that in the provided
    //! ECDSA object.
    int(0..1) public_key_equal(this_program ecdsa)
    {
      return ecdsa->get_curve() == Curve::this &&
	ecdsa->get_x() == get_x() &&
	ecdsa->get_y() == get_y();
    }

    //! Compares the keys of this ECDSA object with something other.
    protected int(0..1) _equal(mixed other)
    {
      if (!objectp(other) || (object_program(other) != object_program(this)) ||
	  !public_key_equal([object(this_program)]other)) {
	return 0;
      }
      this_program ecdsa = [object(this_program)]other;
      return get_private_key() == ecdsa->get_private_key();
    }

    //! Set the random function, used to generate keys and parameters,
    //! to the function @[r].
    this_program set_random(function(int:string(8bit)) r)
    {
      ::set_random(r);
      return this;
    }

    //! Generate a new set of private and public keys on the current curve.
    this_program generate_key()
    {
      ::generate_key();
      return this;
    }

    //! Get the ANSI x9.62 4.3.6 encoded uncompressed public key.
    string(8bit) get_public_key()
    {
      return sprintf("%c%*c%*c",
		     4,	// Uncompressed.
		     (size() + 7)>>3, get_x(),
		     (size() + 7)>>3, get_y());
    }

    Point get_point()
    {
      return Point(get_x(), get_y());
    }

    //! Get the JWS algorithm identifier for a hash.
    //!
    //! @returns
    //!   Returns @expr{0@} (zero) on failure.
    //!
    //! @seealso
    //!   @rfc{7518:3.1@}
    string(7bit) jwa(.Hash hash)
    {
      switch(Curve::name() + ":" + hash->name()) {
      case "SECP_256R1:sha256":
	return "ES256";
      case "SECP_384R1:sha384":
	return "ES384";
      case "SECP_521R1:sha512":
	return "ES512";
      }
      return 0;
    }

    //! Signs the @[message] with a PKCS-1 signature using hash algorithm
    //! @[h].
    string(8bit) pkcs_sign(string(8bit) message, .Hash h)
    {
      array sign = map(raw_sign(h->hash(message)), Integer);
      return Sequence(sign)->get_der();
    }

    //! Verify PKCS-1 signature @[sign] of message @[message] using hash
    //! algorithm @[h].
    int(0..1) pkcs_verify(string(8bit) message, .Hash h, string(8bit) sign)
    {
      Object a = Standards.ASN1.Decode.secure_der_decode(sign);

      // The signature is the DER-encoded ASN.1 sequence Ecdsa-Sig-Value
      // with the two integers r and s. See RFC 4492 section 5.4.
      if (!a
	  || (a->type_name != "SEQUENCE")
	  || (sizeof([array]a->elements) != 2)
	  || (sizeof( ([array(object(Object))]a->elements)->type_name -
		      ({ "INTEGER" }))))
	return 0;

      return raw_verify(h->hash(message),
			[object(Gmp.mpz)]([array(object(Object))]a->elements)[0]->
			value,
			[object(Gmp.mpz)]([array(object(Object))]a->elements)[1]->
			value);
    }

    //! Signs the @[message] with a JOSE JWS ECDSA signature using hash
    //! algorithm @[h].
    //!
    //! @param message
    //!   Message to sign.
    //!
    //! @param h
    //!   Hash algorithm to use.
    //!
    //! @returns
    //!   Returns the signature on success, and @expr{0@} (zero)
    //!   on failure.
    //!
    //! @seealso
    //!   @[pkcs_verify()], @[salt_size()], @rfc{7515@}
    string(7bit) jose_sign(string(8bit) message, .Hash|void h,
			   mapping(string(7bit):string(7bit)|int)|void headers)
    {
      if (!h) {
	switch(Curve::name()) {
	case "SECP_256R1":
	  h = .SHA256;
	  break;
#if constant(Nettle.SHA384)
        case "SECP_384R1":
	  h = .SHA384;
          break;
#endif
#if constant(Nettle.SHA512)
	case "SECP_521R1":
	  h = .SHA512;
	  break;
#endif
        default:
	  return 0;
	}
      }
      string(7bit) alg = jwa(h);
      if (!alg) return 0;
      headers = headers || ([]);
      headers += ([ "alg": alg ]);
      string(7bit) tbs =
	sprintf("%s.%s",
		MIME.encode_base64url(string_to_utf8(Standards.JSON.encode(headers))),
		MIME.encode_base64url(message));
      array(Gmp.mpz) raw = raw_sign(h->hash(tbs));
      int bytes = ((size()+7)>>3);
      string(8bit) raw_bin = sprintf("%*c%*c", bytes, raw[0], bytes, raw[1]);
      return sprintf("%s.%s", tbs, MIME.encode_base64url(raw_bin));
    }

    //! Verify and decode a JOSE JWS ECDSA signed value.
    //!
    //! @param jws
    //!   A JSON Web Signature as returned by @[jose_sign()].
    //!
    //! @returns
    //!   Returns @expr{0@} (zero) on failure, and an array
    //!   @array
    //!     @elem mapping(string(7bit):string(7bit)|int) 0
    //!       The JOSE header.
    //!     @elem string(8bit) 1
    //!       The signed message.
    //!   @endarray
    //!
    //! @seealso
    //!   @[pkcs_verify()], @rfc{7515:3.5@}
    array(mapping(string(7bit):
		  string(7bit)|int)|string(8bit)) jose_decode(string(7bit) jws)
    {
      array(string(7bit)) segments = [array(string(7bit))](jws/".");
      if (sizeof(segments) != 3) return 0;
      mapping(string(7bit):string(7bit)|int) headers;
      catch {
	headers = [mapping(string(7bit):string(7bit)|int)](mixed)
	  Standards.JSON.decode(utf8_to_string(MIME.decode_base64url(segments[0])));
	if (!mappingp(headers)) return 0;
	.Hash h;
	switch(headers->alg) {
        case "ES256":
	  h = .SHA256;
	  break;
#if constant(Nettle.SHA384)
        case "ES384":
	  h = .SHA384;
	  break;
#endif
#if constant(Nettle.SHA512)
        case "ES512":
	  h = .SHA512;
          break;
#endif
        default:
	  return 0;
	}
	string(7bit) tbs = sprintf("%s.%s", segments[0], segments[1]);
	string(8bit) sign = MIME.decode_base64url(segments[2]);
	if (raw_verify(h->hash(tbs),
		       Gmp.mpz(sign[..<sizeof(sign)/2], 256),
		       Gmp.mpz(sign[sizeof(sign)/2..], 256))) {
	  return ({ headers, MIME.decode_base64url(segments[1]) });
	}
      };
      return 0;
    }

    //! Returns the PKCS-1 algorithm identifier for ECDSA and the provided
    //! hash algorithm. Only SHA-1 and SHA-2 based hashes are supported
    //! currently.
    Sequence pkcs_signature_algorithm_id(.Hash hash)
    {
      switch(hash->name())
      {
      case "sha1":
	return Sequence( ({ Standards.PKCS.Identifiers.ecdsa_sha1_id }) );
      case "sha224":
	return Sequence( ({ Standards.PKCS.Identifiers.ecdsa_sha224_id }) );
      case "sha256":
	return Sequence( ({ Standards.PKCS.Identifiers.ecdsa_sha256_id }) );
      case "sha384":
	return Sequence( ({ Standards.PKCS.Identifiers.ecdsa_sha384_id }) );
      case "sha512":
	return Sequence( ({ Standards.PKCS.Identifiers.ecdsa_sha512_id }) );
      }
      return 0;
    }

    //! Returns the AlgorithmIdentifier as defined in RFC5480 section
    //! 2.1.1 including the ECDSA parameters.
    Sequence pkcs_algorithm_identifier()
    {
      return Curve::pkcs_algorithm_identifier();
    }

    //! Creates a SubjectPublicKeyInfo ASN.1 sequence for the object.
    //! See RFC 5280 section 4.1.2.7.
    Sequence pkcs_public_key()
    {
      return Sequence(({
			pkcs_algorithm_identifier(),
			BitString(get_public_key()),
		      }));
    }
#undef Sequence
#undef Object
#undef Integer
#undef Identifier
#undef BitString

    //! Generate a JWK-style mapping of the object.
    //!
    //! @param private_key
    //!   If true, include the private key in the result.
    //!
    //! @returns
    //!   Returns a JWK-style mapping on success, and @expr{0@} (zero)
    //!   on failure.
    //!
    //! @seealso
    //!   @[create()], @[Web.encode_jwk()], @rfc{7517:4@}, @rfc{7518:6.2@}
    mapping(string(7bit):string(7bit)) jwk(int(0..1)|void private_key)
    {
      string jose_name = Curve::jose_name();
      if (!jose_name) return 0;	// Not supported for this curve.
      int bytes = (size()+7)>>3;
      mapping(string(7bit):string(7bit)) jwk = ([
	"kty":"EC",
	"crv":jose_name,
	"x": MIME.encode_base64url(sprintf("%*c", bytes, get_x())),
	"y": MIME.encode_base64url(sprintf("%*c", bytes, get_y())),
      ]);
      if (private_key) {
	// FIXME: Detect if the private key hasn't been set.
	jwk->d = MIME.encode_base64url(get_private_key()->digits(256));
      }
      return jwk;
    }
  }
}

//! @module SECP_192R1

//! @decl inherit Curve

//! @endmodule

//! @module SECP_224R1

//! @decl inherit Curve

//! @endmodule

//! @module SECP_256R1

//! @decl inherit Curve

//! @endmodule

//! @module SECP_384R1

//! @decl inherit Curve

//! @endmodule

//! @module SECP_521R1

//! @decl inherit Curve

//! @endmodule

//! @ignore
// NB: These constants were added during Pike 8.0.315.
//     Prior to this availability of Nettle.ECC_Curve implied
//     that all of the SECP curves were available.
#if constant(Nettle.SECP192R1) || (__BUILD__ <= 314)
Curve SECP_192R1 = Curve(1, 192, 1);
#endif /* constant(Nettle.SECP192R1) */
#if constant(Nettle.SECP224R1) || (__BUILD__ <= 314)
Curve SECP_224R1 = Curve(1, 224, 1);
#endif /* constant(Nettle.SECP224R1) */
#if constant(Nettle.SECP256R1) || (__BUILD__ <= 314)
Curve SECP_256R1 = Curve(1, 256, 1);
#endif /* constant(Nettle.SECP256R1) */
#if constant(Nettle.SECP384R1) || (__BUILD__ <= 314)
Curve SECP_384R1 = Curve(1, 384, 1);
#endif /* constant(Nettle.SECP384R1) */
#if constant(Nettle.SECP521R1) || (__BUILD__ <= 314)
Curve SECP_521R1 = Curve(1, 521, 1);
#endif /* constant(Nettle.SECP521R1) */
//! @endignore