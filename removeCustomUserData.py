#!/usr/bin/env python3
# encoding: utf-8
'''
    Name of script: removeCustomUserData.py
    Purpose of script: Remove all or parts of custom user attribute data.
    Date: 02/18/21
    Version: 1.0
    Author: Devon Jobes
    Example: 
        % python3 removeCustomUserData.py
        usage: removeCustomUserData.py [-h] [-a ATTRIBUTE] [-d DATA] [-e EMAIL] [-r REMOVEALL]

        optional arguments:
        -h, --help            show this help message and exit
        -a ATTRIBUTE, --attribute ATTRIBUTE
                                OneLogin custome user attribute field.
        -d DATA, --data DATA  Data to add to custom user attribute field.
        -e EMAIL, --email EMAIL
                                Email address of user to update.
        -r REMOVEALL, --removeall REMOVEALL
                                Remove all attributes and update user account.

        # | Removing one item from the list of attribute data
        % python3 removeCustomUserData.py -e "example@example.com" -a "custom_attribute" -d "new-one"
            [SUCCESS][removeCustomUserData] Removed new-one from attribute custom_attribute.
        
        # | Removing all items from the attribute
        % python3 removeCustomUserData.py -e "example@example.com" -a "custom_attribute" -r True
        [SUCCESS][removeCustomUserData] Removed customdata1,customdata2,customdata3 from attribute custom_attribute.
    
'''
# ---------------------------------------------
# | Requirements
# ---------------------------------------------
import os, json, requests, sys, argparse

# ---------------------------------------------
# | Global variables
# ---------------------------------------------

# | Script system path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# | Set Script Working Directory
dn = os.path.dirname(os.path.realpath(__file__))
fileName = os.path.splitext(os.path.basename(__file__))[0]

# ----------------------------------------------
# | Helper Scripts
# ----------------------------------------------
from generateToken import getToken

# ---------------------------------------------
# | Code
# ---------------------------------------------
# | Generate access token
token=getToken()

# | Header details
headers = {'Authorization': 'bearer:' + token, 'Content-Type':"application/json", 'Accept':"application/json"}

# | Search for custom user attribute
def checkAttr(attr):
    try:
        attrUrl = 'https://[api-domain].onelogin.com/api/1/users/custom_attributes'
        attrResponse = requests.get(attrUrl, headers=headers)
        attrJson = json.loads(attrResponse.text)
        roleList = [x for x in attrJson['data'][0]]
        roleListSearch = [x.replace("_",' ') for x in attrJson['data'][0]]
        attrLower = attr.lower()
        if attr in roleList:
            rlIndex=roleList.index(attr)
            return roleList[rlIndex]
        elif attrLower in roleListSearch:
            rlIndex=roleListSearch.index(attrLower)
            return roleList[rlIndex]
        else:
            errMsg="[ERROR][{fn}] Couldn't find '{attr}' in {rl}.".format(fn=fileName,attr=attr,rl=roleList)
            print(errMsg)
            sys.exit()
    except Exception as e:
        errMsg="[ERROR][{fn}] Something went wrong looking for '{attr}'.".format(fn=fileName,attr=attr)
        print(errMsg)
        sys.exit()

# | Check to make sure user is in OneLogin
def checkAccount(email,attr):
    try:
        getUrl = 'https://[api-domain].onelogin.com/api/1/users?email={}'.format(email)
        getUser = requests.get(getUrl, headers=headers)
        userStatus = getUser.status_code
        if userStatus == 200:
            userData = json.loads(getUser.text)
            olUID = userData['data'][0]['id']
            olAttr = userData['data'][0]['custom_attributes'][attr]
            return olUID, olAttr
        else:
            errMsg = "[ERROR][{fn}] Couldn't find user with email address: {email}".format(fn=fileName, email=email)
            print(errMsg)
            sys.exit()
    except Exception as e:
        errMsg="[ERROR][{fn}] Something went wrong looking for email or attribute: {email}:{attr}.".format(fn=fileName,email=email, attr=attr)
        print(errMsg)
        sys.exit()

# | Update user attributes
def updateAttributes(id,attr,data,delData,email):
    try:
        putUrl = 'https://[api-domain].onelogin.com/api/1/users/{id}'.format(id=id)
        payload = {"custom_attributes": {attr: data}}
        putResponse = requests.put(putUrl, headers=headers, json=payload)
        putStatus = putResponse.status_code
        if putStatus != 200:
            errMsg="[ERROR][{fn}] Error Code: {err} Couldnt update user account: {email}".format(fn=fileName,err=putResponse.status_code,email=email)
            print(errMsg)
            sys.exit()
        else:
            sucMsg = "[SUCCESS][{fn}] Removed '{data}' from attribute '{attr}' for {email}.".format(fn=fileName,attr=attr,data=delData,email=email)
            return sucMsg
    except Exception as e:
        errMsg="[ERROR][{fn}] Something went wrong updating account: {id}".format(fn=fileName,id=id)
        print(errMsg)
        sys.exit()

# | Script arguments
def parse_args():  
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("-a", "--attribute", help="OneLogin custom user attribute field.", action="store")
    parser.add_argument("-d", "--data", help="Data to add to custom user attribute field.", action="store")
    parser.add_argument("-e", "--email", help="Email address of user to update.", action="store")  
    parser.add_argument("-r", "--removeall", help="Remove all attributes and update user account.", action="store", default=False)
    args = parser.parse_args(None if sys.argv[1:] else ['-h'])
    return args

def main():
    # | Function results
    arg = parse_args()  

    # | Command line arguments
    email = arg.email
    attribute = arg.attribute
    remove = arg.removeall
    data = arg.data + ";"

    try:
        # | Check to make sure attribute is valid
        attr = checkAttr(attribute)
        # | Get user ID
        olUID, olAttr = checkAccount(email, attr)
        if remove == 'True':
            delData = olAttr
            data = ''
            print(updateAttributes(olUID,attr,data,delData,email))
        else:
            # | Remove use role data
            if data in olAttr:
                delData = data.replace(';','')
                data = olAttr.replace(data,'')
                print(updateAttributes(olUID,attr,data,delData,email))
            else:
                errMsg="[ERROR][{fn}] Can't find '{data}' in user {email} custom '{attr}' to remove.".format(fn=fileName,data=data,email=email,attr=attr)
                print(errMsg)
                
    except Exception as e:
        exception_type, exception_traceback = sys.exc_info()
        line_number = exception_traceback.tb_lineno
        print(e)
        print(exception_type)
        print(line_number)
        sys.exit()

if __name__ == '__main__':
    main()