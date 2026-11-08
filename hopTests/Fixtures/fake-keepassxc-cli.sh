#!/bin/sh
# Stand-in for keepassxc-cli: accepts the password "secret" on stdin and prints a CSV export.
read -r pw
if [ "$pw" != "secret" ]; then
  echo "Error while reading the database: Invalid credentials were provided, please try again." >&2
  exit 1
fi
cat <<'CSV'
"Group","Title","Username","Password","URL","Notes","TOTP","Icon","Last Modified","Created"
"Root","GitHub","alice","hunter2","https://github.com","","","0","",""
"Root/Recycle Bin","Gone","x","x","","","","0","",""
CSV
