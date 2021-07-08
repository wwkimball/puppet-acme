# @summary A request to sign a CSR or renew a certificate.
#
# @param csr
#   The full CSR as a string.
#
# @param domain
#   Certificate commonname / domainname.
#
# @param use_account
#   The Let's Encrypt account that should be used.
#
# @param use_profile
#   The profile that should be used to sign the certificate.
#
# @param letsencrypt_ca
#   The Let's Encrypt CA you want to use. Used to overwrite the default Let's
#   Encrypt CA that is configured on `$acme_host`.
#
# @api private
define acme::request (
  String $csr,
  String $use_account,
  String $use_profile,
  String $domain = $name,
  Integer $renew_days = $acme::renew_days,
  Boolean $ocsp_must_staple = true,
  Optional[Array] $altnames = undef,
  Optional[Enum['production','staging']] $letsencrypt_ca = undef,
) {
  $user = $acme::user
  $group = $acme::group
  $base_dir = $acme::base_dir
  $acme_dir = $acme::acme_dir
  $cfg_dir = $acme::cfg_dir
  $crt_dir = $acme::crt_dir
  $csr_dir = $acme::csr_dir
  $acct_dir = $acme::acct_dir
  $log_dir = $acme::log_dir
  $results_dir = $acme::results_dir
  $acme_install_dir = $acme::acme_install_dir
  $path = $acme::path
  $stat_expression = $acme::stat_expression

  # acme.sh configuration
  $acmecmd = $acme::acmecmd
  $acmelog = $acme::acmelog
  $csr_file = "${csr_dir}/${domain}/cert.csr"
  $crt_file = "${crt_dir}/${domain}/cert.pem"
  $chain_file = "${crt_dir}/${domain}/chain.pem"
  $fullchain_file = "${crt_dir}/${domain}/fullchain.pem"

  # Check if the account is actually defined.
  $accounts = $acme::accounts
  if ! ($use_account in $accounts) {
    fail("Module ${module_name}: account \"${use_account}\" for cert ${domain}",
      "is not defined on \$acme_host")
  }
  $account_email = $use_account

  # Check if the profile is actually defined.
  $profiles = $acme::profiles
  #if ($profiles == Hash) and $profiles[$use_profile] {
  if $profiles[$use_profile] {
    $profile = $profiles[$use_profile]
  } else {
    fail("Module ${module_name}: unable to find profile \"${use_profile}\" for",
      "cert ${domain}")
  }
  $challengetype = $profile['challengetype']
  $hook = $profile['hook']

  # We need to tell acme.sh when to use LE staging servers.
  if ( $letsencrypt_ca == 'staging' ) {
    $staging_or_not = '--staging'
  } else {
    $staging_or_not = ''
  }

  $account_conf_file = "${acct_dir}/${account_email}/account_${letsencrypt_ca}.conf"

  # Add ocsp if must-staple is requested
  if ($ocsp_must_staple) {
    $_ocsp = '--ocsp'
  } else {
    $_ocsp = ''
  }

  # Collect options for "supported" hooks.
  if ($challengetype == 'dns-01') {
    # DNS-01 / nsupdate hook
    if ($hook == 'nsupdate') {
      $nsupdate_id = $profile['options']['nsupdate_id']
      $nsupdate_key = $profile['options']['nsupdate_key']
      $nsupdate_type = $profile['options']['nsupdate_type']
      if ($nsupdate_id and $nsupdate_key and $nsupdate_type) {
        $hook_dir = "${cfg_dir}/profile_${use_profile}"
        $hook_conf_file = "${hook_dir}/hook.cnf"
        $_hook_params_pre = { 'NSUPDATE_KEY' => $hook_conf_file }
      }
    }
  }
  # Merge those pre-defined hook options with user-defined hook options.
  # NOTE: We intentionally use Hashes so that *values* can be overriden.
  if ($_hook_params_pre =~ Hash) {
    $_hook_params = deep_merge($_hook_params_pre, $profile['env'])
  } elsif ($profile and $profile['env'] =~ Hash) {
    $_hook_params = $profile['env']
  } else {
    $_hook_params = {}
  }

  # Convert the Hash to an Array, required for Exec's "environment" attribute.
  $hook_params = $_hook_params.map |$key,$value| { "${key}=${value}" }
  notify { "hook params for domain ${domain}: ${hook_params}": loglevel => debug }

  # Collect additional options for acme.sh.
  if ($profile['options']['dnssleep']
      and ($profile['options']['dnssleep'] =~ Integer)
      and ($profile['options']['dnssleep'] > 0)) {
    $_dnssleep = "--dnssleep  ${profile['options']['dnssleep']}"
  } elsif (defined('$acme::dnssleep') and ($acme::dnssleep > 0)) {
    $_dnssleep = "--dnssleep ${::acme::dnssleep}"
  } else {
    # Let acme.sh poll dns status automatically.
    $_dnssleep = ''
  }

  # Use the challenge or domain alias that is specified in the profile
  if ($profile['options']['challenge_alias']) {
    $_alias_mode = "--challenge-alias ${profile['options']['challenge_alias']}"
    $acme_options = join([$_dnssleep, $_alias_mode], ' ')
  } elsif ($profile['options']['domain_alias']) {
    $_alias_mode = "--domain-alias ${profile['options']['domain_alias']}"
    $acme_options = join([$_dnssleep, $_alias_mode], ' ')
  } else {
    $acme_options = $_dnssleep
  }

  File {
    owner   => $user,
    group   => $group,
    require => [
      User[$user],
      Group[$group]
    ],
  }

  # NOTE: We need to use a different directory on $acme_host to avoid
  #       duplicate declaration errors (in cases where the CSR was also
  #       generated on $acme_host).
  file { "${csr_dir}/${domain}":
    ensure => directory,
    mode   => '0755',
  }

  file { $csr_file :
    ensure  => file,
    content => $csr,
    mode    => '0640',
  }

  # Create directory to place the crt_file for each domain
  $crt_dir_domain = "${crt_dir}/${domain}"
  ensure_resource('file', $crt_dir_domain, {
    ensure  => directory,
    mode    => '0755',
    owner   => $user,
    group   => $group,
    require => [
      User[$user],
      Group[$group]
    ],
  })

  # Places where acme.sh stores the resulting certificate.
  $le_crt_file = "${acme_dir}/${domain}/${domain}.cer"
  $le_chain_file = "${acme_dir}/${domain}/ca.cer"
  $le_fullchain_file = "${acme_dir}/${domain}/fullchain.cer"

  # We create a copy of the resulting certificates in a separate folder
  # to make it easier to collect them with facter.
  # XXX: Also required by acme::request::crt.
  $result_crt_file = "${results_dir}/${domain}.pem"
  $result_chain_file = "${results_dir}/${domain}.ca"

  # Convert altNames to be compatible with acme.sh.
  $_altnames = $altnames.map |$item| { "--domain ${item}" }

  # Convert days to seconds for openssl...
  $renew_seconds = $renew_days*86400
  notify { "acme renew set to ${renew_days} days (or ${renew_seconds} seconds) for domain ${domain}": loglevel => debug }

  # NOTE: If the CSR file is newer than the cert, this check will trigger
  # a renewal of the cert. However, acme.sh may not recognize the change
  # in the CSR or decide that the change does not need a renewal of the cert.
  # In this case it will be triggered on every Puppet run, until $renew_days
  # is reached and acme.sh finally renews the cert. This is a known limitation
  # that does not cause any side-effects.
  $le_check_command = join([
    "test -f \'${le_crt_file}\'",
    '&&',
    "openssl x509 -checkend ${renew_seconds} -noout -in \'${le_crt_file}\'",
    '&&',
    'test',
    "\$( ${stat_expression} \'${le_crt_file}\' )",
    '-gt',
    "\$( ${stat_expression} \'${csr_file}\' )",
  ], ' ')

  # Check if challenge type is supported.
  if $challengetype == 'http-01' {
    # XXX add support for other http-01 hooks
    $acme_challenge = '--webroot /etc/acme.sh/challenges'
  } elsif $challengetype == 'dns-01' {
    # Hook is passed unchecked to acme.sh to automatically support new hooks
    # when they are added to acme.sh.
    $acme_validation = "--dns dns_${hook}"
  } else {
    fail("${::hostname}: Module ${module_name}: unsupported challenge",
      "type \"${challengetype}\"")
  }

  # acme.sh command to sign a new csr.
  $le_command_signcsr = join([
    $acmecmd,
    $staging_or_not,
    '--signcsr',
    "--domain \'${domain}\'",
    $_altnames,
    $acme_validation,
    "--log ${acmelog}",
    '--log-level 2',
    "--home ${acme_dir}",
    '--keylength 4096',
    "--accountconf ${account_conf_file}",
    $_ocsp,
    "--csr \'${csr_file}\'",
    "--cert-file \'${crt_file}\'",
    "--ca-file \'${chain_file}\'",
    "--fullchain-file \'${fullchain_file}\'",
    $acme_options,
    '>/dev/null',
  ], ' ')

  # acme.sh command to renew an existing certificate.
  $le_command_renew = join([
    $acmecmd,
    $staging_or_not,
    '--issue',
    "--domain \'${domain}\'",
    $_altnames,
    $acme_validation,
    "--days ${renew_days}",
    "--log ${acmelog}",
    '--log-level 2',
    "--home ${acme_dir}",
    '--keylength 4096',
    "--accountconf ${account_conf_file}",
    $_ocsp,
    "--csr \'${csr_file}\'",
    "--cert-file \'${crt_file}\'",
    "--ca-file \'${chain_file}\'",
    "--fullchain-file \'${fullchain_file}\'",
    $acme_options,
    '>/dev/null',
  ], ' ')

  # Run acme.sh to issue the certificate
  exec { "issue-certificate-${domain}" :
    user        => $user,
    cwd         => $base_dir,
    group       => $group,
    unless      => $le_check_command,
    path        => $path,
    environment => $hook_params,
    command     => $le_command_signcsr,
    timeout     => $acme::exec_timeout,
    # Run this exec only if no old cert can be found.
    onlyif      => "test ! -f \'${le_crt_file}\'",
    require     => [
      User[$user],
      Group[$group],
      File[$csr_file],
      File[$crt_dir_domain],
      File[$account_conf_file],
      Vcsrepo[$acme_install_dir],
    ],
    notify      => [
      File[$le_crt_file],
      File[$result_crt_file],
      File[$result_chain_file],
    ],
  }

  # Run acme.sh to issue/renew the certificate
  exec { "renew-certificate-${domain}" :
    user        => $user,
    cwd         => $base_dir,
    group       => $group,
    unless      => $le_check_command,
    path        => $path,
    environment => $hook_params,
    command     => $le_command_renew,
    timeout     => $acme::exec_timeout,
    returns     => [ 0, 2, ],
    # Run this exec only if an old cert can be found.
    onlyif      => "test -f \'${le_crt_file}\'",
    require     => [
      User[$user],
      Group[$group],
      File[$csr_file],
      File[$crt_dir_domain],
      File[$account_conf_file],
      Vcsrepo[$acme_install_dir],
    ],
    notify      => [
      File[$le_crt_file],
      File[$result_crt_file],
      File[$result_chain_file],
    ],
  }

  file { $le_crt_file:
    mode    => '0644',
    replace => false,
  }

  file { $result_crt_file:
    source => $le_crt_file,
    mode   => '0644',
  }

  file { $result_chain_file:
    source => $le_chain_file,
    mode   => '0644',
  }

  ::acme::request::ocsp { $domain:
    require => File[$result_crt_file],
  }
}
