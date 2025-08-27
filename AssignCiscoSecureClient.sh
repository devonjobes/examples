#!/bin/zsh
###############################################################
# | Bash strict mode enabled. To disable 
# | strict mode to bypass errors, disable
# | 'set' options when needed. Reference:
# | http://redsymbol.net/articles/unofficial-bash-strict-mode/
###############################################################
set -euo pipefail
IFS=$'\n\t'

##############################################
# | Description: This script will add the computer to the assigned Cisco policy Jamf group and notify the owner that the client is being upgraded.
# |
# | Created by: Devon Jobes
# | Created: 061424
# | Version: 1.0
# | Example:
# | AssignCiscoSecureClient.sh -c C02DQ67WQ05P
# |     =======
# |     -- Assigned C02DQ67WQ05P to App - Cisco Secure Connect Jamf group.
# |     -- Sending notification to person@example.com.
# |     =======
##############################################

##############################################
# | Message handling
##############################################

# | Message prefix
MsgPrefix="[AssignCiscoSecureClient][`date`]"

#############################################
# | Functions / Global Variables
#############################################
# | Error function
ErrorExit(){
    # | Error message
    ErrMsg="${MsgPrefix}: [ErrorCode] $?."
    echo $ErrMsg 1>&2
}

Help(){
   # Display Help
   echo "This script assigns the Cisco Secure Client to computers to update the client."
   echo
   echo "Syntax: scriptTemplate [c|h]"
   echo "options:"
   echo "c     Serial number or name of computer."
   echo "h     Print this Help."
   echo
}

# | Command line variables
while getopts h:c: flag
do
    case $flag in
        c) computerSerial=${OPTARG} ;;
        h) Help
           exit;;
        \?) # Invalid option
         echo "Error: Invalid option"
         exit;;
    esac
done

computer=$computerSerial

GetToken(){
    getAuthResponse=$(curl -s -X POST -u "$JAMF_USER":"$JAMF_CRED" https://[custom-domain].jamfcloud.com/api/v1/auth/token)
    getAuthToken=$(echo $getAuthResponse | jq -r '.token')
}

GetCompObject(){
    getComp=$(curl -s -X GET -w "\n%{http_code}" -H "Authorization: Bearer $getAuthToken" -H $acceptHeader "https://[custom-domain].jamfcloud.com/JSSResource/computers/match/$1")
    getCompBodyResponse=$(echo -E $getComp | sed '$d')
    getCompStatusResponse=$(echo -E $getComp | tail -n 1)
    if [[ $getCompStatusResponse -eq 200 ]]
    then
        getCompID=$(echo -E $getCompBodyResponse | jq -r '.computers.[].id')
        getCompAssignedAccount=$(echo -E $getCompBodyResponse | jq -r '.computers.[].email')
    else
        echo " -- Something went wrong searching for $1."
        echo $getCompBodyResponse
        echo -e "=======\n"
        exit 1
    fi
}

EmailNotification(){
    echo " -- Sending notification to $1."
    curl -s --url 'smtps://smtp.gmail.com:465' \
    --ssl-reqd --mail-from 'example@example.com' \
    --mail-rcpt "$1" --user "thepersonsendingtheemail@example.com:$GMAIL" \
    -T <(echo -e "$2")
}

AddToStaticGroup(){
    xmlAttribute="<computer_group><computer_additions><computer><id>"$1"</id></computer></computer_additions></computer_group>"
    addToGroup=$(curl -s -X PUT -w "\n%{http_code}" -H "content-type: text/xml" -H "Authorization: Bearer $getAuthToken" "https://[custom-domain].jamfcloud.com/JSSResource/computergroups/id/$2" --data $xmlAttribute)
    addToGroupBodyResponse=$(echo $addToGroup | sed '$d')
    addToGroupStatusResponse=$(echo $addToGroup | tail -n 1)
    if [[ $addToGroupStatusResponse -eq 201 ]]
    then
        echo " -- Assigned $computer to App - Cisco Secure Connect Jamf group."
    else
        echo " -- Something went wrong adding $computer to App - Cisco Secure Connect Jamf group."
        echo $addToGroupBodyResponse
        echo -e "=======\n"
        exit 1
    fi
}

###############################################
# | Try the script and catch errors
###############################################

echo "======="
GetToken
GetCompObject $computer
emailMessage=$(cat <<EOF
From: Example User <example@example.com>
To: $getCompAssignedAccount
Subject: [NOTICE] Cisco Umbrella Update

Hello,

You are receiving this email because your Cisco Umbrella client will be updated to the latest version shortly. If you notice any issues with web pages not loading correctly please restart your computer.

If you are still having issues after a restart please email get-some-help@example.com.

Thanks,

Example Team

EOF
)
AddToStaticGroup $getCompID 331
#EmailNotification $getCompAssignedAccount $emailMessage
echo -e "=======\n"

exit 0  