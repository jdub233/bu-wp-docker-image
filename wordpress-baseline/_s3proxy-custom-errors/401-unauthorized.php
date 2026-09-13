<?php
// mod_shib publishes a base URL that needs '/Login?target=' appended; the edge SP sends a complete
// URL-encoded login URL to use verbatim. Check mod_shib first: its value comes from the subprocess
// environment rather than from the request.
$login_url = '';

if ( ! empty( $_SERVER['Shib-Handler'] ) ) {
	$login_url = $_SERVER['Shib-Handler'] . '/Login?target=' . rawurlencode( $_SERVER['SCRIPT_URI'] ?? '' );
} else {
	// The edge name is per-stack: X-CF-Shib-Handler on www-test and www-syst, SHIB-HANDLER elsewhere.
	foreach ( array( 'HTTP_X_CF_SHIB_HANDLER', 'HTTP_SHIB_HANDLER' ) as $edge_header ) {
		if ( ! empty( $_SERVER[ $edge_header ] ) ) {
			$login_url = urldecode( $_SERVER[ $edge_header ] );
			break;
		}
	}
}

// The login target must stay on this host. A handler with no host is already a path on this site.
if ( '' !== $login_url ) {
	$login_host = parse_url( $login_url, PHP_URL_HOST );
	$same_host  = ( null === $login_host )
		|| ( is_string( $login_host ) && 0 === strcasecmp( $login_host, $_SERVER['HTTP_HOST'] ?? '' ) );

	if ( ! $same_host ) {
		$login_url = '';
	}
}

// With no handler, render the page rather than redirect to a relative path nothing serves.
// The HTML below is for browsers that don't follow the location header.
if ( '' !== $login_url ) {
	header( 'Location: ' . $login_url );
}

// Apache serves this file directly, so WordPress is not loaded and esc_html() is unavailable.
$requested = htmlspecialchars( $_SERVER['REQUEST_URI'] ?? '', ENT_QUOTES, 'UTF-8' );
$login_out = htmlspecialchars( $login_url, ENT_QUOTES, 'UTF-8' );
?>
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>401 Unauthorized</title>
<?php if ( '' !== $login_url ) : ?>
<meta http-equiv="refresh" content="0; URL='<?php echo $login_out; ?>'" />
<?php endif; ?>
</head><body>
<h1>401 Unauthorized</h1>
<p>
    You have requested a restricted resource ( <?php echo $requested; ?> ), but are not logged in.
<?php if ( '' !== $login_url ) : ?>
    <a href="<?php echo $login_out; ?>">Log in to see protected content</a>
<?php else : ?>
    No login service is configured for this site, so there is no way to sign in from here.
<?php endif; ?>
</p>
</body></html>
