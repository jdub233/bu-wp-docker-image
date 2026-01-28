<?php
// Calculate the URL to redirect to the login page.
$login_url = $_SERVER['Shib-Handler'] . '/Login?target=' . rawurlencode( $_SERVER['SCRIPT_URI'] );

// Emit a location header to force a redirect to the login page.
// The rest of the HTML is just for browsers that don't follow the location header.
header('Location: ' . $login_url);
?>
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>401 Unauthorized</title>
<meta http-equiv="refresh" content="0; URL='<?php echo $login_url ?>'" />
</head><body>
<h1>401 Unauthorized</h1>
<p>
    You have requested a restricted resource ( <?php echo $_SERVER['REQUEST_URI'] ?> ), but are not logged in. 
    <a href="<?php echo $login_url ?>">Log in to see protected content</a>
</p>
</body></html>
