PowerShell Example
--------
##### Script name: [*Get-AuthenticatedCompters*](../master/scripts/Get-AuthenticatedComputers.ps1)
##### Purpose of script:
  Without the availabilty of a tool to audit how many computers were utilizing the office LAN, the Windows Security Event log was parsed to audit successfull Radius authentication requests for both wired and wireless networks and was used to match computer to owner, connection type (wired or wireless) and what network device the computer connected to.
##### End result:
  Daily CSV was created and emailed to business units who needed the data for processing.

Python Example
--------
##### Script name: [*removeCustomUserData.py*](../master/scripts/removeCustomUserData.py)
##### Purpose of script:
  Requests to remove all or partial data from custom attributes in OneLogin were repeated often, required an admin to log into the OneLogin admin portal to perform the action manually and could take anywhere from 5-15 minutes per request.
##### End result:
  This script reduced the admin processing from up to 15 minutes to less than 30 seconds for most requests.

Bash Example
--------
##### Script name: [*AssignCiscoSecureClient.sh*](../master/scripts/AssignCiscoSecureClient.sh)
##### Purpose of script:
  To push out an update to the Cisco Secure Client, a Jamf Static Group was used to assign endpoints to a policy that upgraded the client once the endpoint was added to the group and sent an email notifing the endpoint owner that the client was being upgraded which lists initial troubleshooting steps and where to get help if needed.
##### End result:
  Allowed targeted roll-out of updated client to specific endpoints and eliminated hours of manual admin overhead time of adding endpoints to the Static Group and sending email notifications.  

Local LLM/Kubernetes Example
-------
#### Architecture description: [*Personal Assistant Bot*](../master/architecture/README.md)
#### Purpose of architecture:
  Create a personal assistant to help keep family schedule synchronized, keep personal data private and to keep costs of LLM workflows affordable.
#### End result:
  Using an OpenClaw gateway as the harness/agent, the server is able to connect to all the services required, (Gmail, Gcal, WhatsApp, Outlook and Monday), to help keep the care schedule synchronized for parents and children. The only new cost added was the cost of the MiniForums AI mini-computer. No additional costs for ISP or power and no additional space needed to store servers or networking equipment because of small form factor. All personal data is kept locally on the server or inside the services connected to the server. Dedicated `bot` account allowcated to the server to ensure further data privacy. 
