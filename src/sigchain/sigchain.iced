{athrow, a_json_parse} = require('iced-utils').util
{make_esc} = require 'iced-error'
kbpgp = require('kbpgp')
proofs = require('keybase-proofs')
ie = require('iced-error')


exports.ParsedKeys = class ParsedKeys
  @parse : ({bundles_list}, cb) ->
    # We only take key bundles from the server, either hex NaCl public keys, or
    # ascii-armored PGP public key strings. We compute the KIDs and
    # fingerprints ourselves, because we don't trust the server to do it for
    # us.
    esc = make_esc cb, "ParsedKeys.parse"
    key_managers = {}
    pgp_to_kid = {}
    kid_to_pgp = {}
    kids_in_order = []  # for testing
    for bundle in bundles_list
      await kbpgp.ukm.import_armored_public {armored: bundle}, esc defer key_manager
      kid = key_manager.get_ekid()
      kid_str = kid.toString "hex"
      key_managers[kid_str] = key_manager
      kids_in_order.push(kid_str)
      fingerprint = key_manager.get_pgp_fingerprint()
      if fingerprint?
        # Only PGP keys have a non-null fingerprint.
        fingerprint_str = fingerprint.toString "hex"
        key_managers[fingerprint.toString "hex"] = key_manager
        pgp_to_kid[fingerprint_str] = kid_str
        kid_to_pgp[kid_str] = fingerprint_str
    parsed_keys = new ParsedKeys {key_managers, pgp_to_kid, kid_to_pgp, kids_in_order}
    cb null, parsed_keys

  constructor : ({@key_managers, @pgp_to_kid, @kid_to_pgp, @kids_in_order}) ->


class ChainLink
  @parse : ({sig_blob, parsed_keys}, cb) ->
    esc = make_esc cb, "ChainLink.parse"
    # Compute the sig_id ourselves.
    sig_buffer = new Buffer(sig_blob.sig, "base64")
    sig_id = kbpgp.hash.SHA256(sig_buffer).toString("hex")
    # Get the ctime and the KID directly from the server blob. These are the
    # only pieces of data that we don't get from the unboxed sig payload,
    # because we need them to do the uboxing. We check them against what's in
    # the box immediately after, and freak out of there's a difference.
    kid = sig_blob.kid
    ctime_seconds = sig_blob.ctime
    # Unbox the signed payload. PGP key expiration is checked automatically
    # during unbox, using the ctime of the chainlink.
    key_manager = parsed_keys.key_managers[kid]
    if not key_manager?
      await athrow (new E.NonexistentKidError "link signed by nonexistent kid #{kid}"), esc defer()
    await key_manager.make_sig_eng().unbox(
      sig_blob.sig,
      defer(err, payload_buffer),
      {now: ctime_seconds})
    if err?
      await athrow (new E.VerifyFailedError err.message), esc defer()
    # Compute the payload_hash ourselves.
    payload_hash = kbpgp.hash.SHA256(payload_buffer).toString("hex")
    # Parse the payload.
    payload_json = payload_buffer.toString('utf8')
    await a_json_parse payload_json, esc defer payload
    # Make sure the KID and ctime from the blob match the payload, and that any
    # payload PGP fingerprint also matches the KID.
    await @_check_payload_against_blob {signing_kid: kid, signing_ctime: ctime_seconds, payload, parsed_keys}, esc defer()
    # Check any reverse signatures.
    await @_check_reverse_signatures {payload, parsed_keys}, esc defer()
    # The constructor takes care of all the payload parsing that isn't failable.
    cb null, new ChainLink {kid, sig_id, payload, payload_hash}

  @_check_payload_against_blob : ({signing_kid, signing_ctime, payload, parsed_keys}, cb) ->
    payload_kid = payload.body.key.kid
    payload_fingerprint = payload.body.key.fingerprint
    payload_ctime = payload.ctime
    err = null
    if payload_kid? and payload_kid isnt signing_kid
      err = new E.KidMismatchError "signing kid (#{signing_kid}) and payload kid (#{payload_kid}) mismatch"
    else if payload_fingerprint? and payload_fingerprint isnt parsed_keys.kid_to_pgp[signing_kid]
      err = new E.FingerprintMismatchError "signing kid (#{signing_kid}) and payload fingerprint (#{payload_fingerprint}) mismatch"
    else if payload_ctime isnt signing_ctime
      err = new E.CtimeMismatchError "payload ctime (#{payload_ctime}) doesn't match signing ctime (#{signing_ctime})"
    cb err

  @_check_reverse_signatures : ({payload, parsed_keys}, cb) ->
    esc = make_esc cb, "ChainLink._check_reverse_signatures"
    if not payload.body.sibkey?
      cb null
      return
    kid = payload.body.sibkey.kid
    key_manager = parsed_keys.key_managers[kid]
    if not key_manager?
      await athrow (new E.NonexistentKidError "link reverse-signed by nonexistent kid #{kid}"), esc defer()
    sibkey_proof = new proofs.Sibkey {}
    await sibkey_proof.reverse_sig_check {json: payload, subkm: key_manager}, defer err
    if err?
      await athrow (new E.VerifyFailedError err.message), esc defer()
    cb null

  constructor : ({@kid, @sig_id, @payload, @payload_hash}) ->
    @uid = @payload.body.key.uid
    @username = @payload.body.key.username
    @seqno = @payload.seqno
    @prev = @payload.prev
    # @fingerprint is PGP-only.
    @fingerprint = @payload.body.key.fingerprint
    # Not all links have the "eldest_kid" field, but if they don't, then their
    # signing KID is implicitly the eldest.
    @eldest_kid = @payload.body.key.eldest_kid or @kid
    @ctime_seconds = @payload.ctime
    @etime_seconds = @ctime_seconds + @payload.expire_in

    @sibkey_delegation = @payload.body.sibkey?.kid
    @subkey_delegation = @payload.body.subkey?.kid

    @key_revocations = []
    if @payload.body.revoke?.kids?
      @key_revocations = @payload.body.revoke.kids
    if @payload.body.revoke?.kid?
      @key_revocations.push(@payload.body.revoke.kid)

    @sig_revocations = []
    if @payload.body.revoke?.sig_ids?
      @sig_revocations = @payload.body.revoke.sig_ids
    if @payload.body.revoke?.sig_id?
      @sig_revocations.push(@payload.body.revoke.sig_id)


exports.SigChain = class SigChain
  @replay : ({sig_blobs, parsed_keys, uid, username, eldest_kid}, cb) ->
    esc = make_esc cb, "SigChain.replay"
    if not eldest_kid?
      # Forgetting the eldest KID would silently give you an empty sigchain. Prevent this.
      await athrow (new Error "eldest_kid parameter is required"), esc defer()
    sigchain = new SigChain {uid, username, eldest_kid}
    for sig_blob in sig_blobs
      await sigchain._add_new_link {sig_blob, parsed_keys}, esc defer()
    cb null, sigchain

  # NOTE: Don't call the constructor directly. Use SigChain.replay().
  constructor : ({uid, username, eldest_kid}) ->
    @_uid = uid
    @_username = username
    @_eldest_kid = eldest_kid
    @_links = []
    @_unrevoked_links = {}
    @_sibkeys_to_etime_seconds = {}
    @_valid_sibkeys = {}
    @_valid_sibkeys[eldest_kid] = true

  # Return the list of links in the current subchain which have not been
  # revoked.
  get_links : () ->
    return (link for link in @_links when link.sig_id of @_unrevoked_links)

  # Return the list of sibkey KIDs which have not been revoked.
  get_sibkeys : () ->
    return (kid for kid of @_valid_sibkeys)

  _add_new_link : ({sig_blob, parsed_keys}, cb) ->
    esc = make_esc cb, "SigChain._add_new_link"

    # This constructor checks that the link is internally consistent: its
    # signature is valid and belongs to the key it claims, and the same for any
    # reverse sigs.
    await ChainLink.parse {sig_blob, parsed_keys}, esc defer link

    # Filter on eldest KID. We do this using verified ChainLink data, because
    # otherwise the server could lie about what a link's eldest_kid was,
    # tricking us into discarding good links from the front of the chain.
    if link.eldest_kid isnt @_eldest_kid
      cb()
      return

    # Next we need to check that the signing key is in the family, unless this
    # is the very first link (in which case the key family is empty).
    await @_check_key_is_valid {link}, esc defer()

    # Finally, check that the link belongs at this point in the chain.
    await @_check_link_belongs_here {link}, esc defer()

    # At this point, we've confirmed the link belongs here. Update all the
    # relevant metadata.
    @_links.push(link)
    @_unrevoked_links[link.sig_id] = link

    await @_delegate_keys {link}, esc defer()

    await @_revoke_keys_and_sigs {link}, esc defer()

    cb null

  _check_key_is_valid : ({link}, cb) ->
    err = null
    if link.kid not of @_valid_sibkeys
      err = new E.InvalidSibkeyError "not a valid sibkey: #{link.kid} valid sibkeys: #{JSON.stringify(@_valid_sibkeys)}"
    else if link.ctime_seconds > @_sibkeys_to_etime_seconds[link.kid]
      err = new E.ExpiredSibkeyError "expired sibkey: #{link.kid}"
    cb err

  _check_link_belongs_here : ({link}, cb) ->
    last_link = @_links[@_links.length-1]  # null if this is the first link
    err = null
    if link.uid isnt @_uid
      err = new E.WrongUIDError """link doesn't refer to the right uid
                                 expected: #{link.uid}
                                      got: #{@_uid}"""
    else if link.username isnt @_username
      err = new E.WrongUsernameError """link doesn't refer to the right username
                                      expected: #{link.username}
                                           got: #{@_username}"""
    else if last_link? and link.seqno isnt last_link.seqno + 1
      err = new E.WrongSeqnoError """link sequence number is wrong
                                   expected: #{last_link.seqno + 1}
                                        got: #{link.seqno}"""
    else if last_link? and link.prev isnt last_link.payload_hash
      err = new E.WrongPrevError """previous payload hash doesn't match,
                                  expected: #{last_link.payload_hash}
                                       got: #{link.prev}"""
    cb err

  _delegate_keys : ({link}, cb) ->
    if link.sibkey_delegation?
      @_valid_sibkeys[link.sibkey_delegation] = true
      @_sibkeys_to_etime_seconds[link.sibkey_delegation] = link.etime_seconds
    # The eldest key is valid from the beginning, but it doesn't get an etime
    # until the first link.
    if link.kid is @_eldest_kid and @_eldest_kid not of @_sibkeys_to_etime_seconds
      @_sibkeys_to_etime_seconds[@_eldest_kid] = link.etime_seconds
    cb()

  _revoke_keys_and_sigs : ({link}, cb) ->
    # Handle direct sibkey revocations.
    for kid in link.key_revocations
      if kid of @_valid_sibkeys
        delete @_valid_sibkeys[kid]

    # Handle revocations of an entire link.
    for sig_id in link.sig_revocations
      if sig_id of @_unrevoked_links
        revoked_link = @_unrevoked_links[sig_id]
        delete @_unrevoked_links[sig_id]
        # Keys delegated by the revoked link are implicitly revoked as well.
        revoked_kid = revoked_link.sibkey_delegation
        if revoked_kid? and revoked_kid of @_valid_sibkeys
          delete @_valid_sibkeys[revoked_kid]
    cb()

exports.E = E = ie.make_errors {
  "NONEXISTENT_KID": ""
  "VERIFY_FAILED": ""
  "KID_MISMATCH": ""
  "FINGERPRINT_MISMATCH": ""
  "CTIME_MISMATCH": ""
  "INVALID_SIBKEY": ""
  "EXPIRED_SIBKEY": ""
  "WRONG_UID": ""
  "WRONG_USERNAME": ""
  "WRONG_SEQNO": ""
  "WRONG_PREV": ""
}
