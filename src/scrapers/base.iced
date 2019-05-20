{constants} = require '../constants'
{v_codes} = constants
pkg = require '../../package.json'
{decode_sig} = require('kbpgp').ukm
{space_normalize} = require '../util'
{b64find} = require '../b64extract'
ipaddress = require 'ip-address'
dns = require 'dns'
http = require 'http'
https = require 'https'

#==============================================================

exports.user_agent = user_agent = constants.user_agent + pkg.version

#==============================================================

class BaseScraper
  # is_bad_address takes in address (string) and family (int) [4 - ipv4, 6 - ipv6]
  constructor : ({@libs, log_level, @proxy, @ca, @is_bad_address}) ->
    @log_level = log_level or "debug"

  hunt : (username, proof_check_text, cb) -> hunt2 { username, proof_check_text }, cb
  hunt2 : (args, cb) -> cb new Error "unimplemented"
  id_to_url : (username, status_id) ->
  check_status : ({username, url, signature, status_id}, cb) -> cb new Error("check_status not implemented"), v_codes.NOT_FOUND
  _check_args : () -> new Error "unimplemented"
  _check_api_url : () -> false # unimplemented

  #-------------------------------------------------------------

  # Can we trust it over Tor? HTTP and DNS aren't trustworthy over
  # Tor, but HTTPS is.
  get_tor_error : (args) -> [ null, v_codes.OK ]

  #-------------------------------------------------------------

  logl : (level, msg) ->
    if (k = @libs.log)? then k[level](msg)

  #-------------------------------------------------------------

  log : (msg) ->
    if (k = @libs.log)? and @log_level? then k[@log_level](msg)

  #-------------------------------------------------------------

  validate : (args, cb) ->
    err = null
    rc = null
    if (err = @_check_args(args)) then # noop
    else if not @_check_api_url args
      err = new Error "check url failed for #{JSON.stringify args}"
    else
      err = @_validate_text_check args
    unless err?
      await @check_status args, defer err, rc
    cb err, rc

  #-------------------------------------------------------------

  # Given a validated signature, check that the payload_text_check matches the sig.
  _validate_text_check : ({signature, proof_text_check }) ->
    [err, msg] = decode_sig { armored: signature }
    # PGP sigs need some newline massaging here, but NaCl sigs don't.
    if not err? and ("\n\n" + msg.payload + "\n") isnt proof_text_check and msg.payload isnt proof_text_check
      err = new Error "Bad payload text_check"
    return err

  #-------------------------------------------------------------

  # Convert away from MS-dos style encoding...
  _stripr : (m) ->
    m.split('\r').join('')

  #-------------------------------------------------------------

  _find_sig_in_raw : (proof_text_check, raw) ->
    ptc_buf = Buffer.from proof_text_check, "base64"
    return b64find raw, ptc_buf

  #-------------------------------------------------------------

  _get_url_body: (opts, cb) ->
    ###
      cb(err, status, body) only replies with body if status is 200
    ###
    body = null
    opts.proxy = @proxy if @proxy?
    opts.ca = @ca if @ca?
    opts.timeout = constants.http_timeout unless opts.timeout?
    opts.headers or= {}
    opts.headers["User-Agent"] = (opts.user_agent or user_agent)

    # Tighten up our redirect strategy abunch, since H1'ers can use it to
    # poke around inside our internal network. It might also make sense to have
    # cross-domain checking here too, but that's fine for now.
    followRedirect = (response) =>
      {hostname,port,search} = url.parse response.headers.location
      fail = (why) =>
        @log "Failure in redirect path for #{@hostname}: #{why}"
        false
      if not hostname?.length then return fail("no hostname")
      if port? and not(port in [ 80, 443 ]) then return fail("bad port: #{port}")
      if new ipaddress.Address4(hostname).isValid() then return fail("found an IPv4 address (#{hostname})")
      if new ipaddress.Address6(hostname).isValid() then return fail("found an IPv6 address (#{hostname})")
      if search? then return fail("found a search parameter (#{search})")
      true

    opts.followRedirect = followRedirect

    lookup = (hostname, options, callback) ->
      filtered_callback = (err, addr, family) ->
        if not err? and @is_bad_address? and @is_bad_address(addr, family)
          err = E.make "blacklisted ip address #{addr} on ipv#{family}"
        callback(err, addr, family)
      dns.lookup(hostname, options, filtered_callback)
    opts.agent = (_parsedURL) ->
      if _parsedURL.protocol is "http:"
        http.Agent({lookup})
      else
        https.Agent({lookup})

    await @libs.fetch opts.url, opts, defer(err, response, body)
    rc = if err?
      if err.code is 'ETIMEDOUT' then               v_codes.TIMEOUT
      else                                          v_codes.HOST_UNREACHABLE
    else if (response.statusCode in [401,403]) then v_codes.PERMISSION_DENIED
    else if (response.statusCode is 200)       then v_codes.OK
    else if (response.statusCode >= 500)       then v_codes.HTTP_500
    else if (response.statusCode >= 400)       then v_codes.HTTP_400
    else if (response.statusCode >= 300)       then v_codes.HTTP_300
    else                                            v_codes.HTTP_OTHER
    cb err, rc, body

  #--------------------------------------------------------------

#==============================================================

exports.BaseScraper = BaseScraper

#==============================================================

exports.sncmp = sncmp = (a,b) ->
  if not a? or not b? then false
  else
    a = ("" + a).toLowerCase()
    b = ("" + b).toLowerCase()
    (a is b)

#================================================================================
