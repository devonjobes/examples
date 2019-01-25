# Modules needed
import mysql.connector
import csv
import smtplib
from mysql.connector import errorcode
from datetime import date
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders


# SQL host values
config = {'host': 'mysql-server.domain.com', 'user': 'nameofdatabaseuser', 'password': 'password123', 'database':'nameofdatabase'}

try:
  # Connect to SQL host and open connection
  cnx = mysql.connector.connect(**config)
  cursor = cnx.cursor()
  
  # Get all attachment data from database
  query = ("SELECT DISTINCT c.contentid, c.title AS attachmentTitle, u.username AS uploadedBy, co.title AS pageTitle, cn.longval as size, cd.creationdate, c.CONTENT_STATUS "
           "FROM CONTENT AS c JOIN user_mapping AS u ON u.user_key = c.creator "
           "JOIN CONTENT AS co ON c. pageid = co.contentid "
           "JOIN CONTENT AS cd ON c.creationdate = cd.creationdate "
           "JOIN CONTENTPROPERTIES AS cn ON cn.contentid = c.contentid "
           "WHERE c.contenttype = 'ATTACHMENT' AND cn.longval IS NOT NULL")

  # Get results of SQL query
  cursor.execute(query)
  
  # Create date object
  d = date.today()
  d = d.strftime("%m%d%y")
  
  # Close MySQL Query
  cursor.close()
  
  # Output query data to CSV
  csvfile = "confluence-attachments-" + d + ".csv"
  with open(csvfile,'w', encoding='utf-8') as out:
    csv_out=csv.writer(out, lineterminator='\n')
    csv_out.writerow(['attachmentUID','attachmentTitle','uploadedBy','pageTitle','attachmentSize','attachedDate','attachmentStatus'])
    csv_out.writerows(cursor)
  
  # Close CSV file
  csvfile.close()
  
  # Create email message
  fromaddr = "sender@domain.com"
  toaddr = "recipient01@domain.com, recipient02@domain.com"
  
  # Create message headers and body
  msg = MIMEMultipart()
  msg['From'] = fromaddr
  msg['To'] = toaddr
  msg['Subject'] = "Weekly Confluence Attachment Report"
  body = "Report of Confluence attachment data."
  msg.attach(MIMEText(body, 'plain'))
  filename = csvfile
  attachment = open(filename, "rb")
  part = MIMEBase('application', 'octet-stream')
  part.set_payload((attachment).read())
  encoders.encode_base64(part)
  part.add_header('Content-Disposition', "attachment; filename= %s" % filename)
  msg.attach(part)
  
  # Send message using SMTP server with no authentication required
  server = smtplib.SMTP('mail-server.domain.com', 25)
  text = msg.as_string()
  server.sendmail(fromaddr, toaddr, text)
  server.quit()
  
  #Close attachment report
  attachment.close()
  
except mysql.connector.Error as err:
  if err.errno == errorcode.ER_ACCESS_DENIED_ERROR:
    print("Something is wrong with your user name or password")
  elif err.errno == errorcode.ER_BAD_DB_ERROR:
    print("Database does not exist")
  else:
    print("Something went wrong: {}".format(err))
else:
  cnx.close()
