#!/bin/bash
# ========================================
# | Firefox preference file location.
# ========================================
prefile=$(/usr/bin/mdfind -onlyin ~/Library/Application\ Support/Firefox/Profiles -name prefs.js)
# ========================================
# | Check to see if Firefox preference
# | has been generated and append custom
# | preferences to enable automatic
# | kerberos authentication for SSO.
# ========================================
if [ -e "$prefile" ]
  then
    sed -i '' -e '$ a\'$'\n''user_pref("network.automatic-ntlm-auth.trusted-uris", "saml-server-URL.domain.com");''\'$'\n''user_pref("network.negotiate-auth.trusted-uris", "saml-server-URL.domain.com");' "$prefile"
else
  exit 1
fi




