PowerShell Example
--------
##### Script name: [*Get-AuthenticatedCompters*](../master/Get-AuthenticatedComputers.ps1)
##### Purpose of script:
  Without the availabilty of a tool to audit how many computers were utilizing the office LAN, the Windows Security Event log was parsed to audit successfull Radius authentication requests for both wired and wireless networks and was used to match computer to owner, connection type (wired or wireless) and what network device the computer connected to.
##### End Result:
  Daily CSV was created and emailed to business units who needed the data for processing.

Python Example
--------
##### Script name: [*removeCustomUserData.py*](../master/removeCustomUserData.py)
##### Purpose of script:
  Requests to remove all or partial data from custom attributes in OneLogin were repeated often, required an admin to log into the OneLogin admin portal to perform the action manually and could take anywhere from 5-15 minutes per request.
##### End Result:
  This script reduced the admin processing from up to 15 minutes to less than 30 seconds for most requests.

Bash Example
--------
##### Script name: [*AssignCiscoSecureClient.sh*](../master/AssignCiscoSecureClient.sh)
##### Purpose of script:
  To push out an update to the Cisco Secure Client, a Jamf Static Group was used to assign endpoints to a policy that upgraded the client once the endpoint was added to the group and sent an email notifing the endpoint owner that the client was being upgraded which lists initial troubleshooting steps and where to get help if needed.
##### End Result:
  Allowed targeted roll-out of updated client to specific endpoints and eliminated hours of manual admin overhead time of adding endpoints to the Static Group and sending email notifications.  



