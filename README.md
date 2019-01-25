PowerShell Example
--------
##### Script name: [*Get-AuthenticatedCompters*](../master/Get-AuthenticatedComputers.ps1)
##### Purpose of script:
  Without the availabilty of a tool to generate a report for which computers were utilizing the office LAN I used the Windows Security Event log to track successfull Radius authentication for both wired and wireless networks and matched each computer to owner, connection type (wired or wireless) and what network device the computer connected to.
##### End Result:
  Daily CSV was created and emailed to business units who needed the data for processing.

Python Example
--------
##### Script name: [*confluence-attachment-report.py*](../master/confluence-attachment-report.py)
##### Purpose of script:
  In preparation to migrate Confluence data from an on-premise server to the Atlassian cloud, total Confluence attachments needed to be reduced significantly.  This report tracked status, size and owner of all attachments in Confluence and was emailed to project managers to track progress on a weekly basis.
##### End Result:
  Using the weekly report, project managers were able to reduce attachment data transfer requirements from over 250GB to under 70GB and lowered the data migration time to four hours.

Bash Example
--------
##### Script name: [*mod-firefox-preferences.sh*](../master/mod-firefox-preferences.sh)
##### Purpose of script:
  Firefox lacks support to use *Integrated Windows Authentication* for SAML enabled single sign-on resourced by default and requires either manually enabling this support in the hidden configuration menu or custom preferences can be added to the main configuration file with a text editor.
##### End Result:
  Using a combination of Jamf and Bash this script was able to add the custom configuration needed to support SSO for corporate resources without requiring the user to manually configure Firefox and eliminated help desk requests for configuring SSO with Firefox.



