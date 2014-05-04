#pike __REAL_VERSION__
#pragma strict_types
#require constant(SSL.Cipher)

//! SSL.handshake keeps the state relevant for SSL handshaking. This
//! includes a pointer to a context object (which doesn't change), various
//! buffers, a pointer to a session object (reuse or created as
//! appropriate), and pending read and write states being negotiated.
//!
//! Each connection will have two sets of read and write states: The
//! current read and write states used for encryption, and pending read
//! and write states to be taken into use when the current keyexchange
//! handshake is finished.

//#define SSL3_PROFILING

import .Constants;

#ifdef SSL3_DEBUG
#define SSL3_DEBUG_MSG(X ...)  werror(X)
#else /*! SSL3_DEBUG */
#define SSL3_DEBUG_MSG(X ...)
#endif /* SSL3_DEBUG */

.session session;
.context context;

.state pending_read_state;
.state pending_write_state;

/* State variables */

int handshake_state; // Constant.STATE_*

int handshake_finished = 0;

constant CERT_none = 0;
constant CERT_requested = 1;
constant CERT_received = 2;
constant CERT_no_certificate = 3;
int certificate_state;

int expect_change_cipher; /* Reset to 0 if a change_cipher message is
			   * received */

multiset(int) remote_extensions = (<>);

// RFC 5746-related fields
int secure_renegotiation;
string(0..255) client_verify_data = "";
string(0..255) server_verify_data = "";
// 3.2: Initially of zero length for both the
//      ClientHello and the ServerHello.

//! The active @[Cipher.KeyExchange] (if any).
.Cipher.KeyExchange ke;

ProtocolVersion version;
ProtocolVersion client_version; /* Used to check for version roll-back attacks. */
int reuse;

//! A few storage variables for client certificate handling on the client side.
array(int) client_cert_types;
array(string(0..255)) client_cert_distinguished_names;


//! Random cookies, sent and received with the hello-messages.
string(0..255) client_random;
string(0..255) server_random;

constant Session = SSL.session;
#define Packet .Packet

.Alert Alert(int(1..2) level, int(0..255) description, string|void message)
{
  // NB: We are always inherited by SSL.connection.
  return context->alert_factory(this, level, description, version,
				message);
}


int has_application_layer_protocol_negotiation;
string(0..255) next_protocol;

string(8bit) get_signature_algorithms()
{
  ADT.struct sign_algs = ADT.struct();
  foreach(sort(indices(HASH_lookup)), int h) {
    sign_algs->put_uint(h, 1);
    sign_algs->put_uint(SIGNATURE_rsa, 1);
    sign_algs->put_uint(h, 1);
    sign_algs->put_uint(SIGNATURE_dsa, 1);
#if constant(Crypto.ECC.Curve)
    // NB: MD5 is not supported with ECDSA signatures.
    if (h != HASH_md5) {
      sign_algs->put_uint(h, 1);
      sign_algs->put_uint(SIGNATURE_ecdsa, 1);
    }
#endif
  }
  return sign_algs->pop_data();
}

#ifdef SSL3_PROFILING
System.Timer timer = System.Timer();
void addRecord(int t,int s) {
  Stdio.stdout.write("time: %.6f sender: %d type: %s\n", timer->get(), s,
                     fmt_constant(t, "HANDSHAKE"));
}
#endif

string(0..255) handshake_messages;

Packet handshake_packet(int(0..255) type, string data)
{

#ifdef SSL3_PROFILING
  addRecord(type,1);
#endif
  /* Perhaps one need to split large packages? */
  Packet packet = Packet();
  packet->content_type = PACKET_handshake;
  packet->fragment = sprintf("%1c%3H", type, [string(0..255)]data);
  handshake_messages += packet->fragment;
  return packet;
}

Packet server_hello_packet()
{
  ADT.struct struct = ADT.struct();
  /* Build server_hello message */
  struct->put_uint(version, 2); /* version */
  SSL3_DEBUG_MSG("Writing server hello, with version: %s\n",
                 fmt_version(version));
  struct->put_fix_string(server_random);
  struct->put_var_string(session->identity, 1);
  struct->put_uint(session->cipher_suite, 2);
  struct->put_uint(session->compression_algorithm, 1);

  ADT.struct extensions = ADT.struct();

  if (secure_renegotiation) {
    // RFC 5746 3.7:
    // The server MUST include a "renegotiation_info" extension
    // containing the saved client_verify_data and server_verify_data in
    // the ServerHello.
    extensions->put_uint(EXTENSION_renegotiation_info, 2);
    ADT.struct extension = ADT.struct();
    extension->put_var_string(client_verify_data + server_verify_data, 1);

    extensions->put_var_string(extension->pop_data(), 2);
  }

  if (session->max_packet_size != PACKET_MAX_SIZE) {
    // RFC 3546 3.2.
    ADT.struct extension = ADT.struct();
    extension->put_uint(EXTENSION_max_fragment_length, 2);
    switch(session->max_packet_size) {
    case 512:  extension->put_uint(FRAGMENT_512,  1); break;
    case 1024: extension->put_uint(FRAGMENT_1024, 1); break;
    case 2048: extension->put_uint(FRAGMENT_2048, 1); break;
    case 4096: extension->put_uint(FRAGMENT_4096, 1); break;
    default:
      return Alert(ALERT_fatal, ALERT_illegal_parameter,
		   "Invalid fragment size.\n");
    }
    extensions->put_var_string(extension->pop_data(), 2);
  }

  if (sizeof(session->ecc_curves) &&
      remote_extensions[EXTENSION_ec_point_formats]) {
    // RFC 4492 5.2:
    // The Supported Point Formats Extension is included in a
    // ServerHello message in response to a ClientHello message
    // containing the Supported Point Formats Extension when
    // negotiating an ECC cipher suite.
    ADT.struct extension = ADT.struct();
    extension->put_uint(POINT_uncompressed, 1);
    extension->put_var_string(extension->pop_data(), 1);
    extensions->put_uint(EXTENSION_ec_point_formats, 2);
    extensions->put_var_string(extension->pop_data(), 2);
  }

  if (session->truncated_hmac) {
    // RFC 3546 3.5 "Truncated HMAC"
    extensions->put_uint(EXTENSION_truncated_hmac, 2);
    extensions->put_var_string("", 2);
  }

  if (session->heartbeat_mode) {
    // RFC 6520
    ADT.struct extension = ADT.struct();
    extension->put_uint(HEARTBEAT_MODE_peer_allowed_to_send, 1);
    extensions->put_uint(EXTENSION_heartbeat, 2);
    extensions->put_var_string(extension->pop_data(), 2);
  }

  if (has_application_layer_protocol_negotiation &&
      next_protocol)
  {
    extensions->put_uint(EXTENSION_application_layer_protocol_negotiation,2);
    extensions->put_uint(sizeof(next_protocol)+3, 2);
    extensions->put_uint(sizeof(next_protocol)+1, 2);
    extensions->put_var_string(next_protocol, 1);
  }

  if (!extensions->is_empty())
      struct->put_var_string(extensions->pop_data(), 2);

  string data = struct->pop_data();
  return handshake_packet(HANDSHAKE_server_hello, data);
}

Packet server_key_exchange_packet()
{
  if (ke) error("KE!\n");
  ke = session->ke_factory(context, session, this, client_version);
  string data = ke->server_key_exchange_packet(client_random, server_random);
  return data && handshake_packet(HANDSHAKE_server_key_exchange, data);
}

Packet client_key_exchange_packet()
{
  ke = ke || session->ke_factory(context, session, this, client_version);
  string data =
    ke->client_key_exchange_packet(client_random, server_random, version);
  if (!data) {
    send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
		      "Invalid KEX.\n"));
    return 0;
  }

  array(.state) res =
    session->new_client_states(this, client_random, server_random, version);
  pending_read_state = res[0];
  pending_write_state = res[1];

  return handshake_packet(HANDSHAKE_client_key_exchange, data);
}

// FIXME: The certificate code has changed, so this no longer works,
// if it ever did.
#if 0
Packet certificate_verify_packet()
{
  ADT.struct struct = ADT.struct();

  // FIXME: This temporary context is probably not needed.
  .context cx = .context();
  cx->private_key = context->private_key;

  session->cipher_spec->sign(cx, handshake_messages, struct);

  return handshake_packet (HANDSHAKE_certificate_verify,
			  struct->pop_data());
}
#endif

int(0..1) not_ecc_suite(int cipher_suite)
{
  array(int) suite = [array(int)]CIPHER_SUITES[cipher_suite];
  return suite &&
    !(< KE_ecdh_ecdsa, KE_ecdhe_ecdsa, KE_ecdh_rsa, KE_ecdhe_rsa >)[suite[0]];
}

int(-1..0) reply_new_session(array(int) cipher_suites,
			     array(int) compression_methods)
{
  SSL3_DEBUG_MSG("ciphers: me:\n%s, client:\n%s",
		 .Constants.fmt_cipher_suites(context->preferred_suites),
                 .Constants.fmt_cipher_suites(cipher_suites));
  cipher_suites = context->preferred_suites & cipher_suites;
  SSL3_DEBUG_MSG("intersection:\n%s\n",
                 .Constants.fmt_cipher_suites((array(int))cipher_suites));

  if (!sizeof(session->ecc_curves) || (session->ecc_point_format == -1)) {
    // No overlapping support for ecc.
    // Filter the ECC suites from the set.
    SSL3_DEBUG_MSG("ECC not supported.\n");
    cipher_suites = filter(cipher_suites, not_ecc_suite);
  }

  if (!sizeof(cipher_suites) ||
      !session->select_cipher_suite(context, cipher_suites, version)) {
    // No overlapping cipher suites, or obsolete cipher suite selected,
    // or incompatible certificates.
    SSL3_DEBUG_MSG("No common suites.\n");
    send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
		      "No common suites!\n"));
    return -1;
  }

  compression_methods = context->preferred_compressors & compression_methods;
  if (sizeof(compression_methods))
    session->set_compression_method(compression_methods[0]);
  else
  {
    SSL3_DEBUG_MSG("Unsupported compression method.\n");
    send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
		      "Unsupported compression method.\n"));
    return -1;
  }
  
  send_packet(server_hello_packet());

  // Don't send any certificate in anonymous mode.
  if (session->cipher_spec->sign != .Cipher.anon_sign) {
    /* Send Certificate, ServerKeyExchange and CertificateRequest as
     * appropriate, and then ServerHelloDone.
     *
     * NB: session->certificate_chain is set by
     *     session->select_cipher_suite() above.
     */
    if (session->certificate_chain)
    {
      SSL3_DEBUG_MSG("Sending Certificate.\n");
      send_packet(certificate_packet(session->certificate_chain));
    } else {
      // Otherwise the server will just silently send an invalid
      // ServerHello sequence.
      error ("Certificate(s) missing.\n");
    }
  }

  Packet key_exchange = server_key_exchange_packet();

  if (key_exchange) {
    send_packet(key_exchange);
  }
  if (context->auth_level >= AUTHLEVEL_ask)
  {
    // we can send a certificate request packet, even if we don't have
    // any authorized issuers.
    send_packet(certificate_request_packet(context)); 
    certificate_state = CERT_requested;
  }
  send_packet(handshake_packet(HANDSHAKE_server_hello_done, ""));
  return 0;
}

Packet change_cipher_packet()
{
  Packet packet = Packet();
  packet->content_type = PACKET_change_cipher_spec;
  packet->fragment = "\001";
  return packet;
}

string(0..255) hash_messages(string(0..255) sender)
{
  if(version == PROTOCOL_SSL_3_0) {
    return .Cipher.MACmd5(session->master_secret)->hash(handshake_messages + sender) +
      .Cipher.MACsha(session->master_secret)->hash(handshake_messages + sender);
  }
  else if(version <= PROTOCOL_TLS_1_1) {
    return session->cipher_spec->prf(session->master_secret, sender,
				     Crypto.MD5.hash(handshake_messages)+
				     Crypto.SHA1.hash(handshake_messages), 12);
  } else if(version >= PROTOCOL_TLS_1_2) {
    return session->cipher_spec->prf(session->master_secret, sender,
				     session->cipher_spec->hash->hash(handshake_messages), 12);
  }
}

Packet finished_packet(string(0..255) sender)
{
  SSL3_DEBUG_MSG("Sending finished_packet, with sender=\""+sender+"\"\n" );
  string(0..255) verify_data = hash_messages(sender);
  if (handshake_state >= STATE_client_min) {
    // We're the client.
    client_verify_data = verify_data;
  } else {
    // We're the server.
    server_verify_data = verify_data;
  }
  return handshake_packet(HANDSHAKE_finished, verify_data);
}

Packet certificate_request_packet(SSL.context context)
{
    /* Send a CertificateRequest message */
    ADT.struct struct = ADT.struct();
    struct->put_var_uint_array(context->preferred_auth_methods, 1, 1);
    if (version >= PROTOCOL_TLS_1_2) {
      // TLS 1.2 has var_uint_array of hash and sign pairs here.
      struct->put_var_string(get_signature_algorithms(), 2);
    }
    struct->put_var_string([string(0..255)]
			   sprintf("%{%2H%}", context->authorities_cache), 2);
    return handshake_packet(HANDSHAKE_certificate_request,
				 struct->pop_data());
}

Packet certificate_packet(array(string(0..255)) certificates)
{
  ADT.struct struct = ADT.struct();
  int len = 0;

  if(certificates && sizeof(certificates))
    len = `+( @ Array.map(certificates, sizeof));
  //  SSL3_DEBUG_MSG("SSL.handshake: certificate_message size %d\n", len);
  struct->put_uint(len + 3 * sizeof(certificates), 3);
  foreach(certificates, string(0..255) cert)
    struct->put_var_string(cert, 3);

  return handshake_packet(HANDSHAKE_certificate, struct->pop_data());
}

Packet heartbeat_packet(string(8bit) s)
{
  Packet packet = Packet();
  packet->content_type = PACKET_heartbeat;
  packet->fragment = s;
  return packet;
}

protected Crypto.AES heartbeat_encode;
protected Crypto.AES heartbeat_decode;

Packet heartbleed_packet()
{
  if (!heartbeat_encode) {
    // NB: We encrypt the payload with a random AES key
    //     to reduce the amount of known plaintext in
    //     the heartbeat masseages. This is needed now
    //     that many cipher suites (such as GCM and CCM)
    //     use xor with a cipher stream, to reduce risk
    //     of revealing larger segments of the stream.
    heartbeat_encode = Crypto.AES();
    heartbeat_decode = Crypto.AES();
    string(8bit) heartbeat_key = random_string(16);
    heartbeat_encode->set_encrypt_key(heartbeat_key);
    heartbeat_decode->set_decrypt_key(heartbeat_key);
  }

  // This packet probes for the Heartbleed vulnerability (CVE-2014-0160)
  // by crafting a heartbeat packet with insufficient (0) padding.
  //
  // If we get a response, the peer doesn't validate the message sizes
  // properly, and probably suffers from the Heartbleed vulnerability.
  //
  // Note that we don't use negative padding (as per the actual attack),
  // to avoid actually stealing information from the peer.
  //
  // Note that we detect the packet on return by it having all zeros
  // in the second field.
  ADT.struct hb_msg = ADT.struct();
  hb_msg->put_uint(HEARTBEAT_MESSAGE_request, 1);
  hb_msg->put_uint(16, 2);
  int now = gethrtime();
  hb_msg->put_fix_string(heartbeat_encode->crypt(sprintf("%8c%8c", now, 0)));
  // No padding.
  return heartbeat_packet(hb_msg->pop_data());
}

string(0..255) server_derive_master_secret(string(0..255) data)
{
  string(0..255)|int(0..255) res =
    ke->server_derive_master_secret(data, client_random, server_random, version);
  if (stringp(res)) return [string]res;
  send_packet(Alert(ALERT_fatal, [int(0..255)]res,
		    "Failed to derive master secret.\n"));
  return 0;
}


// verify that a certificate chain is acceptable
//
int verify_certificate_chain(array(string) certs)
{
  // do we need to verify the certificate chain?
  if(!context->verify_certificates)
    return 1;

  // if we're not requiring the certificate, and we don't provide one, 
  // that should be okay. 
  if((context->auth_level < AUTHLEVEL_require) && !sizeof(certs))
    return 1;

  // a lack of certificates when we reqiure and must verify the
  // certificates is probably a failure.
  if(!certs || !sizeof(certs))
    return 0;


  // See if the issuer of the certificate is acceptable. This means
  // the issuer of the certificate must be one of the authorities.
  if(sizeof(context->authorities_cache))
  {
    string r=Standards.X509.decode_certificate(certs[-1])->issuer
      ->get_der();
    int issuer_known = 0;
    foreach(context->authorities_cache, string c)
    {
      if(r == c) // we have a trusted issuer
      {
        issuer_known = 1;
        break;
      }
    }

    if(issuer_known==0)
    {
      return 0;
    }
  }

  // ok, so we have a certificate chain whose client certificate is 
  // issued by an authority known to us.
  
  // next we must verify the chain to see if the chain is unbroken

  mapping result =
    Standards.X509.verify_certificate_chain(certs,
                                            context->trusted_issuers_cache,
					    context->require_trust);

  if(result->verified)
  {
    // This data isn't actually used internally.
    session->cert_data = result;
    return 1;
  }

 return 0;
}

//! Do handshake processing. Type is one of HANDSHAKE_*, data is the
//! contents of the packet, and raw is the raw packet received (needed
//! for supporting SSLv2 hello messages).
//!
//! This function returns 0 if handshake is in progress, 1 if handshake
//! is finished, and -1 if a fatal error occurred. It uses the
//! send_packet() function to transmit packets.
int(-1..1) handle_handshake(int type, string(0..255) data, string(0..255) raw)
{
  ADT.struct input = ADT.struct(data);
#ifdef SSL3_PROFILING
  addRecord(type,0);
#endif
#ifdef SSL3_DEBUG_HANDSHAKE_STATE
  werror("SSL.handshake: state %s, type %s\n",
	 fmt_constant(handshake_state, "STATE"),
         fmt_constant(type, "HANDSHAKE"));
  werror("sizeof(data)="+sizeof(data)+"\n");
#endif

  switch(handshake_state)
  {
  default:
    error( "Internal error\n" );
  case STATE_server_wait_for_hello:
   {
     array(int) cipher_suites;

     /* Reset all extra state variables */
     expect_change_cipher = certificate_state = 0;
     ke = 0;
     
     handshake_messages = raw;


     // The first four bytes of the client_random is specified to be
     // the timestamp on the client side. This is to guard against bad
     // random generators, where a client could produce the same
     // random numbers if the seed is reused. This argument is flawed,
     // since a broken random generator will make the connection
     // insecure anyways. The standard explicitly allows these bytes
     // to not be correct, so sending random data instead is safer and
     // reduces client fingerprinting.
     server_random = context->random(32);

     switch(type)
     {
     default:
       send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			 "Expected client_hello.\n"));
       return -1;
     case HANDSHAKE_client_hello:
      {
	string id;
	int cipher_len;
	array(int) cipher_suites;
	array(int) compression_methods;

	SSL3_DEBUG_MSG("SSL.handshake: CLIENT_HELLO\n");

       	if (
	  catch{
	    client_version =
	      [int(0x300..0x300)|ProtocolVersion]input->get_uint(2);
	  client_random = input->get_fix_string(32);
	  id = input->get_var_string(1);
	  cipher_len = input->get_uint(2);
	  cipher_suites = input->get_fix_uint_array(2, cipher_len/2);
	  compression_methods = input->get_var_uint_array(1, 1);
	  SSL3_DEBUG_MSG("STATE_server_wait_for_hello: received hello\n"
			 "version = %s\n"
			 "id=%O\n"
			 "cipher suites:\n%s\n"
			 "compression methods: %O\n",
			 fmt_version(client_version),
			 id, .Constants.fmt_cipher_suites(cipher_suites),
                         compression_methods);

	}
	  || (cipher_len & 1))
	{
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Invalid client_hello.\n"));
	  return -1;
	}
	if (((client_version & ~0xff) != PROTOCOL_SSL_3_0) ||
	    (client_version < context->min_version)) {
	  SSL3_DEBUG_MSG("Unsupported version of SSL: %s.\n",
			 fmt_version(client_version));
	  send_packet(Alert(ALERT_fatal, ALERT_protocol_version,
			    "Unsupported version.\n"));
	  return -1;
	}
	if (client_version > version) {
	  SSL3_DEBUG_MSG("Falling back client from %s to %s.\n",
			 fmt_version(client_version),
			 fmt_version(version));
	} else if (version > client_version) {
	  SSL3_DEBUG_MSG("Falling back server from %s to %s.\n",
			 fmt_version(version),
			 fmt_version(client_version));
	  version = client_version;
	}

	ADT.struct extensions;
	if (!input->is_empty()) {
	  extensions = ADT.struct(input->get_var_string(2));
	}

#ifdef SSL3_DEBUG
	if (!input->is_empty())
	  werror("SSL.handshake->handle_handshake: "
		 "extra data in hello message ignored\n");
      
	if (sizeof(id))
	  werror("SSL.handshake: Looking up session %O\n", id);
#endif
	session = sizeof(id) && context->lookup_session(id);
	if (session &&
	    has_value(cipher_suites, session->cipher_suite) &&
	    has_value(compression_methods, session->compression_algorithm)) {
	  // SSL3 5.6.1.2:
	  // If the session_id field is not empty (implying a session
	  // resumption request) this vector [cipher_suites] must
	  // include at least the cipher_suite from that session.
	  // ...
	  // If the session_id field is not empty (implying a session
	  // resumption request) this vector [compression_methods]
	  // must include at least the compression_method from
	  // that session.
	  SSL3_DEBUG_MSG("SSL.handshake: Reusing session %O\n", id);
	  /* Reuse session */
	  reuse = 1;
	} else {
	  session = context->new_session();
	  reuse = 0;
	}

	int missing_secure_renegotiation = secure_renegotiation;
	if (extensions) {
	  int maybe_safari_10_8 = 1;
	  while (!extensions->is_empty()) {
	    int extension_type = extensions->get_uint(2);
	    string(8bit) raw = extensions->get_var_string(2);
	    ADT.struct extension_data = ADT.struct(raw);
	    SSL3_DEBUG_MSG("SSL.handshake->handle_handshake: "
			   "Got extension %s.\n",
			   fmt_constant(extension_type, "EXTENSION"));
	    remote_extensions[extension_type] = 1;
          extensions:
	    switch(extension_type) {
	    case EXTENSION_signature_algorithms:
	      if (!remote_extensions[EXTENSION_ec_point_formats] ||
		  (raw != "\0\12\5\1\4\1\2\1\4\3\2\3") ||
		  (client_version != PROTOCOL_TLS_1_2)) {
		maybe_safari_10_8 = 0;
	      }
	      // RFC 5246
	      string bytes = extension_data->get_var_string(2);
	      // Pairs of <hash_alg, signature_alg>.
	      session->signature_algorithms = ((array(int))bytes)/2;
	      SSL3_DEBUG_MSG("New signature_algorithms:\n"+
			     fmt_signature_pairs(session->signature_algorithms));
	      break;
	    case EXTENSION_elliptic_curves:
	      if (!remote_extensions[EXTENSION_server_name] ||
		  (raw != "\0\6\0\x17\0\x18\0\x19")) {
		maybe_safari_10_8 = 0;
	      }
	      int sz = extension_data->get_uint(2)/2;
	      session->ecc_curves =
		filter(reverse(sort(extension_data->get_fix_uint_array(2, sz))),
		       ECC_CURVES);
	      SSL3_DEBUG_MSG("Elliptic curves: %O\n",
			     map(session->ecc_curves, fmt_constant, "CURVE"));
	      break;
	    case EXTENSION_ec_point_formats:
	      if (!remote_extensions[EXTENSION_elliptic_curves] ||
		  (raw != "\1\0")) {
		maybe_safari_10_8 = 0;
	      }
	      array(int) ecc_point_formats =
		extension_data->get_var_uint_array(1, 1);
	      // NB: We only support the uncompressed point format for now.
	      if (has_value(ecc_point_formats, POINT_uncompressed)) {
		session->ecc_point_format = POINT_uncompressed;
	      } else {
		// Not a supported point format.
		session->ecc_point_format = -1;
	      }
	      SSL3_DEBUG_MSG("Elliptic point format: %O\n",
			     session->ecc_point_format);
	      break;
	    case EXTENSION_server_name:
	      if (sizeof(remote_extensions) != 1) {
		maybe_safari_10_8 = 0;
	      }
	      // RFC 4366 3.1 "Server Name Indication"
	      // Example: "\0\f\0\0\tlocalhost"
	      session->server_names = ({});
	      while (!extension_data->is_empty()) {
		ADT.struct server_name =
		  ADT.struct(extension_data->get_var_string(2));
		switch(server_name->get_uint(1)) {	// name_type
		case 0:	// host_name
		  session->server_names += ({ server_name->get_var_string(2) });
		  break;
		default:
		  // Ignore other NameTypes for now.
		  break;
		}
	      }
              SSL3_DEBUG_MSG("SNI extension: %O\n", session->server_names);
	      break;
	    case EXTENSION_max_fragment_length:
	      // RFC 3546 3.2 "Maximum Fragment Length Negotiation"
	      int mfsz = !extension_data->is_empty() &&
		extension_data->get_uint(1);
	      if (!extension_data->is_empty()) mfsz = 0;
	      switch(mfsz) {
	      case FRAGMENT_512:  session->max_packet_size = 512; break;
	      case FRAGMENT_1024: session->max_packet_size = 1024; break;
	      case FRAGMENT_2048: session->max_packet_size = 2048; break;
	      case FRAGMENT_4096: session->max_packet_size = 4096; break;
	      default:
		send_packet(Alert(ALERT_fatal, ALERT_illegal_parameter,
				  "Invalid fragment size.\n"));
		return -1;
	      }
              SSL3_DEBUG_MSG("Maximum frame size %O.\n", session->max_packet_size);
	      break;
	    case EXTENSION_truncated_hmac:
	      // RFC 3546 3.5 "Truncated HMAC"
	      if (!extension_data->is_empty()) {
		send_packet(Alert(ALERT_fatal, ALERT_illegal_parameter,
				  "Invalid trusted HMAC extension.\n"));
	      }
	      session->truncated_hmac = 1;
              SSL3_DEBUG_MSG("Trucated HMAC\n");
	      break;

	    case EXTENSION_renegotiation_info:
	      string renegotiated_connection =
		extension_data->get_var_string(1);
	      if ((renegotiated_connection != client_verify_data) ||
		  (handshake_finished && !secure_renegotiation)) {
		// RFC 5746 3.7: (secure_renegotiation)
		// The server MUST verify that the value of the
		// "renegotiated_connection" field is equal to the saved
		// client_verify_data value; if it is not, the server MUST
		// abort the handshake.
		//
		// RFC 5746 4.4: (!secure_renegotiation)
		// The server MUST verify that the "renegotiation_info"
		// extension is not present; if it is, the server MUST
		// abort the handshake.
		send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
				  "Invalid renegotiation data.\n"));
		return -1;
	      }
	      secure_renegotiation = 1;
	      missing_secure_renegotiation = 0;
              SSL3_DEBUG_MSG("Renego extension: %O\n", renegotiated_connection);
	      break;

            case EXTENSION_application_layer_protocol_negotiation:
              {
                has_application_layer_protocol_negotiation = 1;
                if( !context->advertised_protocols )
                  break;
                multiset(string) protocols = (<>);
                if( extension_data->get_uint(2) != sizeof(extension_data) )
                {
                  send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
				    "ALPN: Length mismatch.\n"));
                  return -1;
                }
                while (!extension_data->is_empty()) {
                  string server_name = extension_data->get_var_string(1);
                  if( sizeof(server_name)==0 )
                  {
                    send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
				      "ALPN: Empty protocol.\n"));
                    return -1;
                  }
                  protocols[ server_name ] = 1;
                }

                if( !sizeof(protocols) )
                {
                  // FIXME: What does an empty list mean? Ignore, no
                  // protocol failure or handshake failure? Currently
                  // it will hit the no compatible protocol fatal
                  // alert below.
                }

                // Although the protocol list is sent in client
                // preference order, it is the server preference that
                // wins.
                next_protocol = 0;
                foreach(context->advertised_protocols;; string(0..255) prot)
                  if( protocols[prot] )
                  {
                    next_protocol = prot;
                    break;
                  }
                if( !next_protocol )
                  send_packet(Alert(ALERT_fatal, ALERT_no_application_protocol,
				    "ALPN: No compatible protocol.\n"));
                SSL3_DEBUG_MSG("ALPN extension: %O %O\n",
			       protocols, next_protocol);
              }
              break;

	    case EXTENSION_heartbeat:
	      {
		int hb_mode;
		if (extension_data->is_empty() ||
		    !(hb_mode = extension_data->get_uint(1)) ||
		    !extension_data->is_empty() ||
		    ((hb_mode != HEARTBEAT_MODE_peer_allowed_to_send) &&
		     (hb_mode != HEARTBEAT_MODE_peer_not_allowed_to_send))) {
		  // RFC 6520 2:
		  // Upon reception of an unknown mode, an error Alert
		  // message using illegal_parameter as its
		  // AlertDescription MUST be sent in response.
		  send_packet(Alert(ALERT_fatal, ALERT_illegal_parameter,
				    "Heartbeat: Invalid extension.\n"));
		}
		SSL3_DEBUG_MSG("heartbeat extension: %s\n",
			       fmt_constant(hb_mode, "HEARTBEAT_MODE"));
		session->heartbeat_mode = [int(0..1)]hb_mode;
	      }
	      break;

	    default:
#ifdef SSL3_DEBUG
              werror("Unhandled extension %O (%d bytes)\n",
                     extension_data->buffer, sizeof(extension_data->buffer));
#endif
	      break;
	    }
	  }
	  if (maybe_safari_10_8) {
	    // According to OpenSSL (ssl/t1_lib.c:ssl_check_for_safari()),
	    // the Safari browser versions 10.8.0..10.8.3 have
	    // broken support for ECDHE_ECDSA, but advertise such
	    // suites anyway. We attempt to fingerprint Safari 10.8
	    // above by the set of extensions and the order it
	    // sends them in.
	    SSL3_DEBUG_MSG("Client version: %s\n"
			   "Number of extensions: %d\n",
			   fmt_version(client_version),
			   sizeof(remote_extensions));
	    if (((client_version == PROTOCOL_TLS_1_2) &&
		 ((sizeof(remote_extensions) != 4) ||
		  !remote_extensions[EXTENSION_signature_algorithms])) ||
		((client_version < PROTOCOL_TLS_1_2) &&
		 ((sizeof(remote_extensions) != 3) ||
		  !remote_extensions[EXTENSION_ec_point_formats]))) {
	      maybe_safari_10_8 = 0;
	    }
	    if (maybe_safari_10_8) {
	      SSL3_DEBUG_MSG("Safari 10.8 (or similar) detected.\n");
	      cipher_suites = filter(cipher_suites,
				     lambda(int suite) {
				       return CIPHER_SUITES[suite] &&
					 (CIPHER_SUITES[suite][0] !=
					  KE_ecdhe_ecdsa);
				     });
	      SSL3_DEBUG_MSG("Remaining cipher suites:\n"
			     "%s\n",
			     .Constants.fmt_cipher_suites(cipher_suites));
	    }
	  }
	}
	if (missing_secure_renegotiation) {
	  // RFC 5746 3.7: (secure_renegotiation)
	  // The server MUST verify that the "renegotiation_info" extension is
	  // present; if it is not, the server MUST abort the handshake.
	  send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			    "Missing secure renegotiation extension.\n"));
	  return -1;
	}
	if (has_value(cipher_suites, TLS_empty_renegotiation_info_scsv)) {
	  if (secure_renegotiation || handshake_finished) {
	    // RFC 5746 3.7: (secure_renegotiation)
	    // When a ClientHello is received, the server MUST verify that it
	    // does not contain the TLS_EMPTY_RENEGOTIATION_INFO_SCSV SCSV.  If
	    // the SCSV is present, the server MUST abort the handshake.
	    //
	    // RFC 5746 4.4: (!secure_renegotiation)
	    // When a ClientHello is received, the server MUST verify
	    // that it does not contain the
	    // TLS_EMPTY_RENEGOTIATION_INFO_SCSV SCSV.  If the SCSV is
	    // present, the server MUST abort the handshake.
	    send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			      "SCSV is present.\n"));
	    return -1;
	  } else {
	    // RFC 5746 3.6:
	    // When a ClientHello is received, the server MUST check if it
	    // includes the TLS_EMPTY_RENEGOTIATION_INFO_SCSV SCSV.  If it
	    // does, set the secure_renegotiation flag to TRUE.
	    secure_renegotiation = 1;
	  }
	}

#ifdef SSL3_DEBUG
	if (!input->is_empty())
	  werror("SSL.handshake->handle_handshake: "
		 "extra data in hello message ignored\n");
      
	if (sizeof(id))
	  werror("SSL.handshake: Looking up session %O\n", id);
#endif
	if (reuse) {
	  /* Reuse session */
	  SSL3_DEBUG_MSG("SSL.handshake: Reusing session %O\n", id);
	  if (! ( (cipher_suites & ({ session->cipher_suite }))
		  && (compression_methods & ({ session->compression_algorithm }))))
	  {
	    send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			      "Unsupported saved session state.\n"));
	    return -1;
	  }
	  send_packet(server_hello_packet());

	  array(.state) res;
	  mixed err;
          if( err = catch(res = session->new_server_states(this,
							   client_random,
							   server_random,
							   version)) )
          {
            // DES/DES3 throws an exception if a weak key is used. We
            // could possibly send ALERT_insufficient_security instead.
            send_packet(Alert(ALERT_fatal, ALERT_internal_error,
			      "Internal error.\n"));
            return -1;
          }
	  pending_read_state = res[0];
	  pending_write_state = res[1];
	  send_packet(change_cipher_packet());
	  if(version == PROTOCOL_SSL_3_0)
	    send_packet(finished_packet("SRVR"));
	  else if(version >= PROTOCOL_TLS_1_0)
	    send_packet(finished_packet("server finished"));

	  if (session->heartbeat_mode == HEARTBEAT_MODE_peer_allowed_to_send) {
	    // Probe for the Heartbleed vulnerability (CVE-2014-0160).
	    send_packet(heartbleed_packet());
	  }

	  expect_change_cipher = 1;
	 
	  handshake_state = STATE_server_wait_for_finish;
	} else {
	  /* New session, do full handshake. */
	  
	  int(-1..0) err = reply_new_session(cipher_suites,
					     compression_methods);
	  if (err)
	    return err;
	  handshake_state = STATE_server_wait_for_client;
	}
	break;
      }
     }
     break;
   }
  case STATE_server_wait_for_finish:
    switch(type)
    {
    default:
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Expected next protocol or finished.\n"));
      return -1;
    case HANDSHAKE_next_protocol:
     {
       next_protocol = input->get_var_string(1);
       handshake_messages += raw;
       return 1;
     }
    case HANDSHAKE_finished:
     {
       string(0..255) my_digest;
       string(0..255) digest;
       
       SSL3_DEBUG_MSG("SSL.handshake: FINISHED\n");

       if(version == PROTOCOL_SSL_3_0) {
	 my_digest=hash_messages("CLNT");
	 if (catch {
	   digest = input->get_fix_string(36);
	 } || !input->is_empty())
	   {
	     send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			       "Invalid handshake finished message.\n"));
	     return -1;
	   }
       } else if(version >= PROTOCOL_TLS_1_0) {
	 my_digest=hash_messages("client finished");
	 if (catch {
	   digest = input->get_fix_string(12);
	 } || !input->is_empty())
	   {
	     send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			       "Invalid handshake finished message.\n"));
	     return -1;
	   }
	 

       }

       if ((ke && ke->message_was_bad)	/* Error delayed until now */
	   || (my_digest != digest))
       {
	 if(ke && ke->message_was_bad)
	   SSL3_DEBUG_MSG("message_was_bad\n");
	 if(my_digest != digest)
	   SSL3_DEBUG_MSG("digests differ\n");
	 send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			   "Key exchange failure.\n"));
	 return -1;
       }
       handshake_messages += raw; /* Second hash includes this message,
				   * the first doesn't */
       /* Handshake complete */

       client_verify_data = digest;
       
       if (!reuse)
       {
	 send_packet(change_cipher_packet());
	 if(version == PROTOCOL_SSL_3_0)
	   send_packet(finished_packet("SRVR"));
	 else if(version >= PROTOCOL_TLS_1_0)
	   send_packet(finished_packet("server finished"));

	 if (session->heartbeat_mode == HEARTBEAT_MODE_peer_allowed_to_send) {
	   // Probe for the Heartbleed vulnerability (CVE-2014-0160).
	   send_packet(heartbleed_packet());
	 }

	 expect_change_cipher = 1;
	 context->record_session(session); /* Cache this session */
       }
       handshake_state = STATE_server_wait_for_hello;

       return 1;
     }   
    }
    break;
  case STATE_server_wait_for_client:
    // NB: ALERT_no_certificate can be valid in this state, and
    //     is handled directly by connection:handle_alert().
    handshake_messages += raw;
    switch(type)
    {
    default:
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Expected client KEX or cert.\n"));
      return -1;
    case HANDSHAKE_client_key_exchange:
      SSL3_DEBUG_MSG("SSL.handshake: CLIENT_KEY_EXCHANGE\n");

      if (certificate_state == CERT_requested)
      { /* Certificate must be sent before key exchange message */
	send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			  "Expected client cert.\n"));
	return -1;
      }

      if (!(session->master_secret = server_derive_master_secret(data)))
      {
	return -1;
      } else {

	// trace(1);
	array(.state) res =
	  session->new_server_states(this, client_random, server_random,
				     version);
	pending_read_state = res[0];
	pending_write_state = res[1];
	
        SSL3_DEBUG_MSG("certificate_state: %d\n", certificate_state);
      }
      // TODO: we need to determine whether the certificate has signing abilities.
      if (certificate_state == CERT_received)
      {
	handshake_state = STATE_server_wait_for_verify;
      }
      else
      {
	handshake_state = STATE_server_wait_for_finish;
	expect_change_cipher = 1;
      }

      break;
    case HANDSHAKE_certificate:
     {
       SSL3_DEBUG_MSG("SSL.handshake: CLIENT_CERTIFICATE\n");

       if (certificate_state != CERT_requested)
       {
	 send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			   "Unexpected client cert.\n"));
	 return -1;
       }
       mixed e;
       if (e = catch {
	 int certs_len = input->get_uint(3);
#ifdef SSL3_DEBUG
	 werror("got %d certificate bytes\n", certs_len);
#else
	 certs_len;	// Fix warning.
#endif
	 array(string(8bit)) certs = ({ });
	 while(!input->is_empty())
	   certs += ({ input->get_var_string(3) });

	  // we have the certificate chain in hand, now we must verify them.
          if((!sizeof(certs) && context->auth_level == AUTHLEVEL_require) || 
                     !verify_certificate_chain(certs))
          {
	    send_packet(Alert(ALERT_fatal, ALERT_bad_certificate,
			      "Bad client certificate.\n"));
	    return -1;
          }
          else
          {
	    session->peer_certificate_chain = certs;
          }
       } || !input->is_empty())
       {
	 send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			   "Unexpected client cert.\n"));
	 return -1;
       }	

       if(session->peer_certificate_chain &&
	  sizeof(session->peer_certificate_chain))
          certificate_state = CERT_received;
       else certificate_state = CERT_no_certificate;
       break;
     }
    }
    break;
  case STATE_server_wait_for_verify:
    // compute challenge first, then update handshake_messages /Sigge
    switch(type)
    {
    default:
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Expected cert verify.\n"));
      return -1;
    case HANDSHAKE_certificate_verify:
      SSL3_DEBUG_MSG("SSL.handshake: CERTIFICATE_VERIFY\n");

      if (!ke->message_was_bad)
      {
	int(0..1) verification_ok;
	mixed err = catch {
	    ADT.struct handshake_messages_struct = ADT.struct();
	    handshake_messages_struct->put_fix_string(handshake_messages);
	    verification_ok = session->cipher_spec->verify(
	      session, "", handshake_messages_struct, input);
	  };
#ifdef SSL3_DEBUG
	if (err) {
	  master()->handle_error(err);
	}
#endif
	err = UNDEFINED;	// Get rid of warning.
	if (!verification_ok)
	{
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Verification of CertificateVerify failed.\n"));
	  return -1;
	}
      }
      handshake_messages += raw;
      handshake_state = STATE_server_wait_for_finish;
      expect_change_cipher = 1;
      break;
    }
    break;

  case STATE_client_wait_for_hello:
    if(type != HANDSHAKE_server_hello)
    {
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Expected server hello.\n"));
      return -1;
    }
    else
    {
      SSL3_DEBUG_MSG("SSL.handshake: SERVER_HELLO\n");

      handshake_messages += raw;
      string id;
      int cipher_suite, compression_method;

      version = [int(0x300..0x300)|ProtocolVersion]input->get_uint(2);
      server_random = input->get_fix_string(32);
      id = input->get_var_string(1);
      cipher_suite = input->get_uint(2);
      compression_method = input->get_uint(1);

      if( !has_value(context->preferred_suites, cipher_suite) ||
	  !has_value(context->preferred_compressors, compression_method) ||
	  !session->is_supported_suite(cipher_suite, ~0, version))
      {
	// The server tried to trick us to use some other cipher suite
	// or compression method than we wanted
	version = client_version;
	send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			  "Server selected bad suite.\n"));
	return -1;
      }

      if (((version & ~0xff) != PROTOCOL_SSL_3_0) ||
	  (version < context->min_version)) {
	SSL3_DEBUG_MSG("Unsupported version of SSL: %s.\n",
		       fmt_version(version));
	version = client_version;
	send_packet(Alert(ALERT_fatal, ALERT_protocol_version,
			  "Unsupported version.\n"));
	return -1;
      }
      if (client_version > version) {
	SSL3_DEBUG_MSG("Falling back client from %s to %s.\n",
		       fmt_version(client_version),
		       fmt_version(version));
      } else if (version > client_version) {
	SSL3_DEBUG_MSG("Falling back server from %s to %s.\n",
		       fmt_version(version),
		       fmt_version(client_version));
	version = client_version;
      }

      if (!session->set_cipher_suite(cipher_suite, version,
				     session->signature_algorithms,
				     512)) {
	// Unsupported or obsolete cipher suite selected.
	SSL3_DEBUG_MSG("Unsupported or obsolete cipher suite selected.\n");
	send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			  "Unsupported or obsolete cipher suite.\n"));
	return -1;
      }
      session->set_compression_method(compression_method);
      SSL3_DEBUG_MSG("STATE_client_wait_for_hello: received hello\n"
		     "version = %s\n"
		     "id=%O\n"
		     "cipher suite: %O\n"
		     "compression method: %O\n",
		     fmt_version(version),
		     id, cipher_suite, compression_method);

      int missing_secure_renegotiation = secure_renegotiation;

      if (!input->is_empty()) {
	ADT.struct extensions = ADT.struct(input->get_var_string(2));

	while (!extensions->is_empty()) {
	  int extension_type = extensions->get_uint(2);
	  ADT.struct extension_data =
	    ADT.struct(extensions->get_var_string(2));
	  SSL3_DEBUG_MSG("SSL.handshake->handle_handshake: "
			 "Got extension %s.\n",
			 fmt_constant(extension_type, "EXTENSION"));
	  switch(extension_type) {
	  case EXTENSION_renegotiation_info:
	    string renegotiated_connection = extension_data->get_var_string(1);
	    if ((renegotiated_connection !=
		 (client_verify_data + server_verify_data)) ||
		(handshake_finished && !secure_renegotiation)) {
	      // RFC 5746 3.5: (secure_renegotiation)
	      // The client MUST then verify that the first half of the
	      // "renegotiated_connection" field is equal to the saved
	      // client_verify_data value, and the second half is equal to the
	      // saved server_verify_data value.  If they are not, the client
	      // MUST abort the handshake.
	      //
	      // RFC 5746 4.2: (!secure_renegotiation)
	      // When the ServerHello is received, the client MUST
	      // verify that it does not contain the
	      // "renegotiation_info" extension. If it does, the client
	      // MUST abort the handshake. (Because the server has
	      // already indicated it does not support secure
	      // renegotiation, the only way that this can happen is if
	      // the server is broken or there is an attack.)
	      send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
				"Invalid renegotiation data.\n"));
	      return -1;
	    }
	    secure_renegotiation = 1;
	    missing_secure_renegotiation = 0;
	    break;
	  case EXTENSION_ec_point_formats:
	    array(int) ecc_point_formats =
	      extension_data->get_var_uint_array(1, 1);
	    // NB: We only support the uncompressed point format for now.
	    if (has_value(ecc_point_formats, POINT_uncompressed)) {
	      session->ecc_point_format = POINT_uncompressed;
	    } else {
	      // Not a supported point format.
	      session->ecc_point_format = -1;
	    }
	    break;
	  case EXTENSION_server_name:
            break;

	  case EXTENSION_heartbeat:
	    {
	      int hb_mode;
	      if (extension_data->is_empty() ||
		  !(hb_mode = extension_data->get_uint(1)) ||
		  !extension_data->is_empty() ||
		  ((hb_mode != HEARTBEAT_MODE_peer_allowed_to_send) &&
		   (hb_mode != HEARTBEAT_MODE_peer_not_allowed_to_send))) {
		// RFC 6520 2:
		// Upon reception of an unknown mode, an error Alert
		// message using illegal_parameter as its
		// AlertDescription MUST be sent in response.
		send_packet(Alert(ALERT_fatal, ALERT_illegal_parameter,
				  "Invalid heartbeat extension.\n"));
	      }
	      SSL3_DEBUG_MSG("heartbeat extension: %s\n",
			     fmt_constant(hb_mode, "HEARTBEAT_MODE"));
	      session->heartbeat_mode = [int(0..1)]hb_mode;
	    }
	    break;

	  default:
	    // RFC 5246 7.4.1.4:
	    // If a client receives an extension type in ServerHello
	    // that it did not request in the associated ClientHello, it
	    // MUST abort the handshake with an unsupported_extension
	    // fatal alert.
	    send_packet(Alert(ALERT_fatal, ALERT_unsupported_extension,
			      "Unrequested extension.\n"));
	    return -1;
	  }
	}
      }
      if (missing_secure_renegotiation) {
	// RFC 5746 3.5:
	// When a ServerHello is received, the client MUST verify that the
	// "renegotiation_info" extension is present; if it is not, the
	// client MUST abort the handshake.
	send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			  "Missing secure renegotiation extension.\n"));
	return -1;
      }

      handshake_state = STATE_client_wait_for_server;
      break;
    }
    break;

  case STATE_client_wait_for_server:
    handshake_messages += raw;
    switch(type)
    {
    default:
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Unexpected server message.\n"));
      return -1;
    case HANDSHAKE_certificate:
      {
	SSL3_DEBUG_MSG("SSL.handshake: CERTIFICATE\n");

      // we're anonymous, so no certificate is requred.
      if(ke && ke->anonymous)
         break;

      SSL3_DEBUG_MSG("Handshake: Certificate message received\n");
      int certs_len = input->get_uint(3); certs_len;
      array(string(8bit)) certs = ({ });
      while(!input->is_empty())
	certs += ({ input->get_var_string(3) });

      // we have the certificate chain in hand, now we must verify them.
      if(!verify_certificate_chain(certs))
      {
        werror("Unable to verify peer certificate chain.\n");
        send_packet(Alert(ALERT_fatal, ALERT_bad_certificate,
			  "Bad server certificate chain.\n"));
  	return -1;
      }
      else
      {
        session->peer_certificate_chain = certs;
      }

      mixed error=catch
      {
	session->peer_public_key = Standards.X509.decode_certificate(
                session->peer_certificate_chain[0])->public_key->pkc;
#if constant(Crypto.ECC.Curve)
	if (session->peer_public_key->curve) {
	  session->curve =
	    ([object(Crypto.ECC.SECP_521R1.ECDSA)]session->peer_public_key)->
	    curve();
	}
#endif
      };

      if(error)
	{
	  session->peer_certificate_chain = UNDEFINED;
          SSL3_DEBUG_MSG("Failed to decode certificate!\n");
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Failed to decode server certificate.\n"));
	  return -1;
	}
      
      certificate_state = CERT_received;
      break;
      }

    case HANDSHAKE_server_key_exchange:
      {
	if (ke) error("KE!\n");
	ke = session->ke_factory(context, session, this, client_version);
	if (ke->server_key_exchange(input, client_random, server_random) < 0) {
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Verification of ServerKeyExchange failed.\n"));
	  return -1;
	}
	break;
      }

    case HANDSHAKE_certificate_request:
      SSL3_DEBUG_MSG("SSL.handshake: CERTIFICATE_REQUEST\n");

        // it is a fatal handshake_failure alert for an anonymous server to
        // request client authentication.
        if(ke->anonymous)
        {
	  send_packet(Alert(ALERT_fatal, ALERT_handshake_failure,
			    "Anonymous server requested authentication by "
			    "certificate.\n"));
	  return -1;
        }

        client_cert_types = input->get_var_uint_array(1, 1);
        client_cert_distinguished_names = ({});

	if (version >= PROTOCOL_TLS_1_2) {
	  // TLS 1.2 has var_uint_array of hash and sign pairs here.
	  string bytes = input->get_var_string(2);
	  // Pairs of <hash_alg, signature_alg>.
	  session->signature_algorithms = ((array(int))bytes)/2;
	  SSL3_DEBUG_MSG("New signature_algorithms:\n"+
			 fmt_signature_pairs(session->signature_algorithms));
	}

        int num_distinguished_names = input->get_uint(2);
        if(num_distinguished_names)
        {
          ADT.struct s =
	    ADT.struct(input->get_fix_string(num_distinguished_names));
          while(!s->is_empty())
          {
	    string(8bit) der = s->get_var_string(2);
	    Standards.ASN1.Types.Sequence seq =
	      [object(Standards.ASN1.Types.Sequence)]
	      Standards.ASN1.Decode.simple_der_decode(der);
	    if(object_program(seq) != Standards.ASN1.Types.Sequence)
            {
	      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
				"Badly formed Certificate Request.\n"));
            }
	    client_cert_distinguished_names += ({ der });
            SSL3_DEBUG_MSG("got an authorized issuer: %O\n",
			   Standards.PKCS.Certificate.get_dn_string( seq ));
	  }
        }

      certificate_state = CERT_requested;
      break;

    case HANDSHAKE_server_hello_done:
      SSL3_DEBUG_MSG("SSL.handshake: SERVER_HELLO_DONE\n");

      /* Send Certificate, ClientKeyExchange, CertificateVerify and
       * ChangeCipherSpec as appropriate, and then Finished.
       */
      /* only send a certificate if it's been requested. */
      if(certificate_state == CERT_requested)
      {
        // okay, we have a list of certificate types and dns that are
        // acceptable to the remote server. we should weed out the certs
        // we have so that we only send certificates that match what they 
        // want.

	array(CertificatePair) certs = [array(CertificatePair)]
	  filter(context->find_cert(client_cert_distinguished_names, 1) || ({}),
		 lambda(CertificatePair cp, array(int)) {
		   return has_value(client_cert_types, cp->cert_type);
		 }, client_cert_types);

	if (sizeof(certs)) {
	  session->private_key = certs[0]->key;
          session->certificate_chain = certs[0]->certs;
#ifdef SSL3_DEBUG
	  foreach(session->certificate_chain, string c)
	  {
	    werror("sending certificate: " + Standards.PKCS.Certificate.get_dn_string(Standards.X509.decode_certificate(c)->subject) + "\n");
	  }
#endif

	  send_packet(certificate_packet(session->certificate_chain));
          certificate_state = CERT_received; // we use this as a way of saying "the server received our certificate"
	} else {
	  send_packet(certificate_packet(({})));
          certificate_state = CERT_no_certificate;
	}
      }


      if( !session->has_required_certificates() )
      {
        SSL3_DEBUG_MSG("Certificate message required from server.\n");
        send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
                          "Certificate message missing.\n"));
        return -1;
      }

      Packet key_exchange = client_key_exchange_packet();

      if (key_exchange)
	send_packet(key_exchange);


      // FIXME: The certificate code has changed, so this no longer
      // works, if it every did.
#if 0
      // FIXME: Certificate verify; we should redo this so it makes more sense
      if(certificate_state == CERT_received &&
         sizeof(context->cert_pairs) &&
	 context->private_key)
         // we sent a certificate, so we should send the verification.
      {
         send_packet(certificate_verify_packet());
      }
#endif

      send_packet(change_cipher_packet());

      if(version == PROTOCOL_SSL_3_0)
	send_packet(finished_packet("CLNT"));
      else if(version >= PROTOCOL_TLS_1_0)
	send_packet(finished_packet("client finished"));

      if (session->heartbeat_mode == HEARTBEAT_MODE_peer_allowed_to_send) {
	// Probe for the Heartbleed vulnerability (CVE-2014-0160).
	send_packet(heartbleed_packet());
      }

      handshake_state = STATE_client_wait_for_finish;
      expect_change_cipher = 1;
      break;
    }
    break;

  case STATE_client_wait_for_finish:
    {
    if((type) != HANDSHAKE_finished)
    {
      SSL3_DEBUG_MSG("Expected type HANDSHAKE_finished(%d), got %d\n",
		     HANDSHAKE_finished, type);
      send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			"Expected handshake finished.\n"));
      return -1;
    } else {
      SSL3_DEBUG_MSG("SSL.handshake: FINISHED\n");

      string my_digest;
      if (version == PROTOCOL_SSL_3_0) {
	server_verify_data = input->get_fix_string(36);
	my_digest = hash_messages("SRVR");
      } else if (version >= PROTOCOL_TLS_1_0) {
	server_verify_data = input->get_fix_string(12);
	my_digest = hash_messages("server finished");
      }

      if (my_digest != server_verify_data) {
	SSL3_DEBUG_MSG("Digests differ.\n");
	send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			  "Digests differ.\n"));
	return -1;
      }

      return 1;			// We're done shaking hands
    }
    }
  }
  //  SSL3_DEBUG_MSG("SSL.handshake: messages = %O\n", handshake_messages);
  return 0;
}

//! @param is_server
//!   Whether this is the server end of the connection or not.
//! @param ctx
//!   The context for the connection.
protected void create(SSL.context ctx)
{
  current_read_state = SSL.state(this);
  current_write_state = SSL.state(this);

  if ((ctx->max_version < PROTOCOL_SSL_3_0) ||
      (ctx->max_version > PROTOCOL_TLS_MAX)) {
    ctx->max_version = PROTOCOL_TLS_MAX;
  }

  if (ctx->min_version < PROTOCOL_SSL_3_0) {
    ctx->min_version = PROTOCOL_SSL_3_0;
  } else if (ctx->min_version > ctx->max_version) {
    ctx->min_version = ctx->max_version;
  }

  version = ctx->max_version;
  context = ctx;
}


//
// --- Old connection.pike below
//

//! SSL packet layer.
//!
//! @[SSL.connection] inherits @[SSL.handshake], and in addition to the state in
//! the handshake super class, it contains the current read and write
//! states, packet queues. This object is responsible for receiving and
//! sending packets, processing handshake packets, and providing clear
//! text packets for some application.

// SSL/TLS Protocol Specification documents:
//
// SSL 2		http://wp.netscape.com/eng/security/SSL_2.html
// SSL 3.0		http://wp.netscape.com/eng/ssl3/draft302.txt
//			(aka draft-freier-ssl-version3-02.txt).
// TLS 1.0 (SSL 3.1)	RFC 2246 "The TLS Protocol Version 1.0".
// TLS 1.1 (SSL 3.2)	draft-ietf-tls-rfc2246-bis
// Renegotiation	RFC 5746 "Renegotiation Indication Extension".

.state current_read_state;
.state current_write_state;
string left_over;
Packet packet;

int sent;
int dying;
int closing; // Bitfield: 1 if a close is sent, 2 of one is received.

function(object,int|object,string:void) alert_callback;

constant PRI_alert = 1;
constant PRI_urgent = 2;
constant PRI_application = 3;

protected ADT.Queue alert = ADT.Queue();
protected ADT.Queue urgent = ADT.Queue();
protected ADT.Queue application = ADT.Queue();

//! Called with alert object, sequence number of bad packet,
//! and raw data as arguments, if a bad packet is received.
//!
//! Can be used to support a fallback redirect https->http.
void set_alert_callback(function(object,int|object,string:void) callback)
{
  alert_callback = callback;
}

//! Low-level receive handler. Returns a packet, an alert, or zero if
//! more data is needed to get a complete packet.
protected Packet recv_packet(string data)
{
  string|Packet res;

  //  SSL3_DEBUG_MSG("SSL.connection->recv_packet(%O)\n", data);
  if (left_over || !packet)
  {
    packet = Packet(2048);
    res = packet->recv( (left_over || "")  + data, version);
  }
  else
    res = packet->recv(data, version);

  if (stringp(res))
  { /* Finished a packet */
    left_over = [string]res;
    if (current_read_state) {
      SSL3_DEBUG_MSG("SSL.connection->recv_packet(): version=0x%x\n",
		     version);
      return current_read_state->decrypt_packet(packet, version);
    } else {
      SSL3_DEBUG_MSG("SSL.connection->recv_packet(): current_read_state is zero!\n");
      return 0;
    }
  }
  else /* Partial packet read, or error */
    left_over = 0;

  return [object]res;
}

//! Queues a packet for write. Handshake and and change cipher
//! must use the same priority, so must application data and
//! close_notifies.
void send_packet(object packet, int|void priority)
{
  if (closing & 1) {
    SSL3_DEBUG_MSG("SSL.connection->send_packet: ignoring packet after close\n");
    return;
  }

  if (packet->content_type == PACKET_alert &&
      packet->description == ALERT_close_notify)
    closing |= 1;

  if (!priority)
    priority = ([ PACKET_alert : PRI_alert,
		  PACKET_change_cipher_spec : PRI_urgent,
	          PACKET_handshake : PRI_urgent,
		  PACKET_heartbeat : PRI_urgent,
		  PACKET_application_data : PRI_application ])[packet->content_type];
  SSL3_DEBUG_MSG("SSL.connection->send_packet: type %d, desc %d, pri %d, %O\n",
		 packet->content_type, packet->description, priority,
		 packet->fragment[..5]);
  switch (priority)
  {
  default:
    error( "Internal error\n" );
  case PRI_alert:
    alert->put(packet);
    break;
  case PRI_urgent:
    urgent->put(packet);
    break;
  case PRI_application:
    application->put(packet);
    break;
  }

}

//! Extracts data from the packet queues. Returns a string of data
//! to be written, "" if there are no pending packets, 1 of the
//! connection is being closed politely, and -1 if the connection
//! died unexpectedly.
//!
//! This function is intended to be called from an i/o write callback.
string|int to_write()
{
  if (dying)
    return -1;

  Packet packet = [object(Packet)](alert->get() || urgent->get() ||
                                   application->get());
  if (!packet) {
    return closing ? 1 : "";
  }

  SSL3_DEBUG_MSG("SSL.connection: writing packet of type %d, %O\n",
                 packet->content_type, packet->fragment[..6]);
  if (packet->content_type == PACKET_alert)
  {
    if (packet->level == ALERT_fatal) {
      dying = 1;
      // SSL3 5.4:
      // Alert messages with a level of fatal result in the immediate
      // termination of the connection. In this case, other
      // connections corresponding to the session may continue, but
      // the session identifier must be invalidated, preventing the
      // failed session from being used to establish new connections.
      if (session) {
	context->purge_session(session);
      }
    }
  }
  string res = current_write_state->encrypt_packet(packet, version)->send();
  if (packet->content_type == PACKET_change_cipher_spec)
    current_write_state = pending_write_state;
  return res;
}

//! Initiate close.
void send_close()
{
  send_packet(Alert(ALERT_warning, ALERT_close_notify,
                    "Closing connection.\n"), PRI_application);
}

//! Send an application data packet. If the data block is too large
//! then as much as possible of the beginning of it is sent. The size
//! of the sent data is returned.
int send_streaming_data (string(8bit) data)
{
  if (!sizeof(data)) return 0;
  Packet packet = Packet();
  packet->content_type = PACKET_application_data;
  int max_packet_size = session->max_packet_size;
  int size;
  if ((!sent) && (version < PROTOCOL_TLS_1_1) &&
      (session->cipher_spec->cipher_type ==
       CIPHER_block)) {
    // Workaround for the BEAST attack.
    // This method is known as the 1/(n-1) split:
    //   Send just one byte of payload in the first packet
    //   to improve the initialization vectors in TLS 1.0.
    size = sizeof((packet->fragment = data[..0]));
    if (sizeof(data) > 1) {
      // If we have more data, take the opportunity to queue some of it too.
      send_packet(packet);

      packet = Packet();
      packet->content_type = PACKET_application_data;
      size += sizeof((packet->fragment = data[1..max_packet_size-1]));
    }
  } else {
    size = sizeof ((packet->fragment = data[..max_packet_size-1]));
  }
  send_packet (packet);
  sent += size;
  return size;
}

protected int handle_alert(string s)
{
  // sizeof(s)==2, checked at caller.
  int level = s[0];
  int description = s[1];
  if (! (ALERT_levels[level] && ALERT_descriptions[description]))
  {
    send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
		      "invalid alert\n"));
    return -1;
  }
  if (level == ALERT_fatal)
  {
    SSL3_DEBUG_MSG("SSL.connection: Fatal alert %d\n", description);
    return -1;
  }
  if (description == ALERT_close_notify)
  {
    SSL3_DEBUG_MSG("SSL.connection: Close notify  alert %d\n", description);
    closing |= 2;
    return 1;
  }
  if (description == ALERT_no_certificate)
  {
    SSL3_DEBUG_MSG("SSL.connection: No certificate  alert %d\n", description);

    if ((certificate_state == CERT_requested) && (context->auth_level == AUTHLEVEL_ask))
    {
      certificate_state = CERT_no_certificate;
      return 0;
    } else {
      send_packet(Alert(ALERT_fatal,
			((certificate_state == CERT_requested)
			 ? ALERT_handshake_failure
			 : ALERT_unexpected_message),
			"Certificate required.\n"));
      return -1;
    }
  }
#ifdef SSL3_DEBUG
  else
    werror("SSL.connection: Received warning alert %d\n", description);
#endif
  return 0;
}

int handle_change_cipher(int c)
{
  if (!expect_change_cipher || (c != 1))
  {
    SSL3_DEBUG_MSG("SSL.connection: handle_change_cipher: Unexcepted message!");
    send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
		      "Unexpected change cipher!\n"));
    return -1;
  }
  else
  {
    current_read_state = pending_read_state;
    expect_change_cipher = 0;
    return 0;
  }
}

void send_heartbeat()
{
  if (!handshake_finished ||
      (session->heartbeat_mode != HEARTBEAT_MODE_peer_allowed_to_send)) {
    // We're not allowed to send heartbeats.
    return;
  }

  ADT.struct hb_msg = ADT.struct();
  hb_msg->put_uint(HEARTBEAT_MESSAGE_request, 1);
  hb_msg->put_uint(16, 2);
  int now = gethrtime();
  hb_msg->put_fix_string(heartbeat_encode->crypt(sprintf("%8c%8c", now, now)));
  // We pad to an even 64 bytes.
  hb_msg->put_fix_string(random_string(64 - sizeof(hb_msg)));
  send_packet(heartbeat_packet(hb_msg->pop_data()));
}

void handle_heartbeat(string(8bit) s)
{
  if (sizeof(s) < 19) return;	// Minimum size for valid heartbeats.
  ADT.struct hb_msg = ADT.struct(s);
  int hb_type = hb_msg->get_uint(1);
  int hb_len = hb_msg->get_uint(2);

  SSL3_DEBUG_MSG("SSL.connection: Heartbeat %s (%d bytes)",
		 fmt_constant(hb_type, "HEARTBEAT_MESSAGE"), hb_len);

  string(8bit) payload;
  int pad_len = 16;

  // RFC 6520 4:
  // If the payload_length of a received HeartbeatMessage is too
  // large, the received HeartbeatMessage MUST be discarded silently.
  if ((hb_len < 0) || ((hb_len + 16) > sizeof(hb_msg))) {
#ifdef SSL3_SIMULATE_HEARTBLEED
    payload = hb_msg->get_rest();
    if (sizeof(payload) < hb_len) {
      payload = payload + random_string(hb_len - sizeof(payload));
    } else {
      payload = payload[..hb_len-1];
    }
#else
    return;
#endif
  } else {
    payload = hb_msg->get_fix_string(hb_len);
    pad_len = sizeof(hb_msg);
  }

  switch(hb_type) {
  case HEARTBEAT_MESSAGE_request:
    // RFC 6520 4:
    // When a HeartbeatRequest message is received and sending a
    // HeartbeatResponse is not prohibited as described elsewhere in
    // this document, the receiver MUST send a corresponding
    // HeartbeatResponse message carrying an exact copy of the payload
    // of the received HeartbeatRequest.
    hb_msg = ADT.struct();
    hb_msg->put_uint(HEARTBEAT_MESSAGE_response, 1);
    hb_msg->put_uint(hb_len, 2);
    hb_msg->put_fix_string(payload);
    hb_msg->put_fix_string(random_string(pad_len));
    send_packet(heartbeat_packet(hb_msg->pop_data()));
    break;
  case HEARTBEAT_MESSAGE_response:
    // RFC 6520 4:
    // If a received HeartbeatResponse message does not contain the
    // expected payload, the message MUST be discarded silently.
    if ((sizeof(payload) == 16) && heartbeat_decode) {
      hb_msg = ADT.struct(heartbeat_decode->crypt(payload));
      int a = hb_msg->get_uint(8);
      int b = hb_msg->get_uint(8);
      if (a != b) {
	if (!b) {
	  // Heartbleed probe response.
	  send_packet(Alert(ALERT_fatal, ALERT_insufficient_security,
			    "Peer suffers from a bleeding heart.\n"));
	}
	break;
      }
#ifdef SSL3_DEBUG
      int delta = gethrtime() - a;
      SSL3_DEBUG_MSG("SSL.connection: Heartbeat roundtrip: %dus\n", delta);
#endif
    }
    break;
  default:
    break;
  }
}

string(8bit) alert_buffer = "";
string(8bit) handshake_buffer = "";

//! Main receive handler. Returns a string of received application
//! data, or 1 if a close was received, or -1 if an error occurred.
//!
//! This function is intended to be called from an i/o read callback.
string|int got_data(string|int s)
{
  if(!stringp(s)) {
    return s;
  }

  if (closing & 2) {
    return 1;
  }
  // If closing == 1 we continue to try to read a remote close
  // message. That enables the caller to check for a clean close, and
  // to get the leftovers after the SSL connection.

  /* If alert_callback is called, this data is passed as an argument */
  string alert_context = (left_over || "") + s;

  string res = "";
  Packet packet;
  while (packet = recv_packet([string]s))
  {
    s = "";

    if (packet->is_alert)
    { /* Reply alert */
      SSL3_DEBUG_MSG("SSL.connection: Bad received packet\n");
      send_packet(packet);
      if (alert_callback)
	alert_callback(packet, current_read_state->seq_num, alert_context);
      if ((!packet) || (!this) || (packet->level == ALERT_fatal))
	return -1;
      if (alert_callback)
	break;
    }
    else
    {
      SSL3_DEBUG_MSG("SSL.connection: received packet of type %d\n",
                     packet->content_type);
      switch (packet->content_type)
      {
      case PACKET_alert:
       {
	 SSL3_DEBUG_MSG("SSL.connection: ALERT\n");

	 int i;
	 int err = 0;
	 alert_buffer += packet->fragment;
	 for (i = 0;
	      !err && ((sizeof(alert_buffer) - i) >= 2);
	      i+= 2)
	   err = handle_alert(alert_buffer[i..i+1]);

	 alert_buffer = alert_buffer[i..];
	 if (err)
	   if (err > 0 && sizeof (res))
	     // If we get a close then we return the data we got so far.
	     return res;
	   else
	     return err;
	 break;
       }
      case PACKET_change_cipher_spec:
       {
	 SSL3_DEBUG_MSG("SSL.connection: CHANGE_CIPHER_SPEC\n");

	 int i;
	 int err;
	 for (i = 0; (i < sizeof(packet->fragment)); i++)
	 {
	   err = handle_change_cipher(packet->fragment[i]);
           SSL3_DEBUG_MSG("tried change_cipher: %d\n", err);
	   if (err)
	     return err;
	 }
	 break;
       }
      case PACKET_handshake:
       {
	 SSL3_DEBUG_MSG("SSL.connection: HANDSHAKE\n");

	 if (handshake_finished && !secure_renegotiation) {
	   // Don't allow renegotiation in unsecure mode, to address
	   // http://web.nvd.nist.gov/view/vuln/detail?vulnId=CVE-2009-3555.
	   // For details see: http://www.g-sec.lu/practicaltls.pdf and
	   // RFC 5746.
	   send_packet(Alert(ALERT_warning, ALERT_no_renegotiation,
			     "Renegotiation not supported in unsecure mode.\n"));
	   return -1;
	 }
	 if (expect_change_cipher)
	 {
	   /* No change_cipher message was received */
	   // FIXME: There's a bug somewhere since expect_change_cipher often
	   // remains set after the handshake is completed. The effect is that
	   // renegotiation doesn't work all the time.
	   //
	   // A side effect is that we are partly invulnerable to the
	   // renegotiation vulnerability mentioned above. It is however not
	   // safe to assume that, since there might be routes past this,
	   // maybe through the use of a version 2 hello message below.
	   send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			     "Expected change cipher.\n"));
	   return -1;
	 }
	 int err, len;
	 handshake_buffer += packet->fragment;

	 while (sizeof(handshake_buffer) >= 4)
	 {
	   sscanf(handshake_buffer, "%*c%3c", len);
	   if (sizeof(handshake_buffer) < (len + 4))
	     break;
	   err = handle_handshake(handshake_buffer[0],
				  handshake_buffer[4..len + 3],
				  handshake_buffer[.. len + 3]);
	   handshake_buffer = handshake_buffer[len + 4..];
	   if (err < 0)
	     return err;
	   if (err > 0) {
	     handshake_finished = 1;
	   }
	 }
	 break;
       }
      case PACKET_application_data:
	SSL3_DEBUG_MSG("SSL.connection: APPLICATION_DATA\n");

	if (!handshake_finished)
	{
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Handshake not finished yet!\n"));
	  return -1;
	}
	res += packet->fragment;
	break;
      case PACKET_heartbeat:
	{
	  // RFC 6520.
	  SSL3_DEBUG_MSG("SSL.connection: Heartbeat.\n");
	  if (!handshake_finished) {
	    // RFC 6520 3:
	    // The receiving peer SHOULD discard the message silently,
	    // if it arrives during the handshake.
	    break;
	  }
	  if (!session->heartbeat_mode) {
	    // RFC 6520 2:
	    // If an endpoint that has indicated peer_not_allowed_to_send
	    // receives a HeartbeatRequest message, the endpoint SHOULD
	    // drop the message silently and MAY send an unexpected_message
	    // Alert message.
	    send_packet(Alert(ALERT_warning, ALERT_unexpected_message,
			      "Heart beat mode not enabled.\n"));
	    break;
	  }
	  handle_heartbeat(packet->fragment);
	}
	break;
      default:
	if (!handshake_finished)
	{
	  send_packet(Alert(ALERT_fatal, ALERT_unexpected_message,
			    "Unexpected message during handshake!\n"));
	  return -1;
	}
	// RFC 4346 6:
	//   If a TLS implementation receives a record type it does not
	//   understand, it SHOULD just ignore it.
	SSL3_DEBUG_MSG("SSL.connection: Ignoring packet of type %s\n",
		       fmt_constant(packet->content_type, "PACKET"));
	break;
      }
    }
  }
  return closing & 2 ? 1 : res;
}
