/*
 * auth_ldap.m
 * OpenVPN LDAP Authentication Plugin
 *
 * Copyright (c) 2005 Landon Fuller <landonf@threerings.net>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of Landon Fuller nor the names of any contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <err.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>

#include <ldap.h>
#include <ctype.h>
#include <curl/curl.h>

#include "openssl/crypto.h"  
#include "openssl/sha.h"  

#include <openvpn-plugin.h>

#include <LFString.h>
#include <LFAuthLDAPConfig.h>
#include <TRLDAPEntry.h>
#include <TRLDAPGroupConfig.h>
#include <LFLDAPConnection.h>
#include <TRPacketFilter.h>
#include <TRPFAddress.h>
#include <TRLog.h>

#define MAX_CURL_RESULT_LENGTH 256
#define MAX_API_PARAMS_COUNT 16

/* Plugin Context */
typedef struct ldap_ctx {
	LFAuthLDAPConfig *config;
#ifdef HAVE_PF
	TRPacketFilter *pf;
#endif
} ldap_ctx;


/* Safe Malloc */
void *xmalloc(size_t size) {
	void *ptr;
	ptr = malloc(size);
	if (!ptr)
		err(1, "malloc returned NULL");

	return (ptr);
}

void *xrealloc(void *oldptr, size_t size) {
	void *ptr;
	ptr = realloc(oldptr, size);
	if (!ptr)
		err(1, "realloc returned NULL");

	oldptr = ptr;

	return (ptr);
}

char *xstrdup(const char *str) {
	void *ptr;
	ptr = strdup(str);
	if (!ptr)
		err(1, "strdup returned NULL");

	return (ptr);
}

char *xstrndup(const char *str, size_t len) {
	void *ptr;
	ptr = strndup(str, len);
	if (!ptr)
		err(1, "strndup returned NULL");

	return (ptr);
}

static const char *get_env(const char *key, const char *env[]) {
	int i;
		
	if (!env)
		return (NULL);

	for (i = 0; env[i]; i++) {
		int keylen = strlen(key);

		if (keylen > strlen(env[i]))
			continue;

		if (!strncmp(key, env[i], keylen)) {
			const char *p = env[i] + keylen;
			if (*p == '=')
				return (p + 1);
		}
	}

	return (NULL);
}

static LFString *quoteForSearch(const char *string)
{
	const char specialChars[] = "*()\\"; /* RFC 2254. We don't care about NULL */
	LFString *result = [[LFString alloc] init];
	LFString *unquotedString, *part;

	/* Make a copy of the string */
	unquotedString = [[LFString alloc] initWithCString: string];

	/* Initialize the result */
	result = [[LFString alloc] init];

	/* Quote all occurrences of the special characters */
	while ((part = [unquotedString substringToCharset: specialChars]) != NULL) {
		LFString *temp;
		int index;
		char c;

		/* Append everything until the first special character */
		[result appendString: part];

		/* Append the backquote */
		[result appendCString: "\\"];

		/* Get the special character */
		index = [unquotedString indexToCharset: specialChars];
		temp = [unquotedString substringFromIndex: index];
		c = [temp charAtIndex: 0];
		[temp release];

		/* Append it, too! */
		[result appendChar: c];

		/* Move unquotedString past the special character */
		temp = [unquotedString substringFromCharset: specialChars];

		[unquotedString release];
		unquotedString = temp;
	}

	/* Append the remainder, if any */
	if (unquotedString) {
		[result appendString: unquotedString];
		[unquotedString release];
	}

	return (result);
}

static LFString *createSearchFilter(LFString *template, const char *username) {
	LFString *templateString;
	LFString *result, *part;
	LFString *quotedName;
	const char userFormat[] = "%u";

	/* Copy the template */
	templateString = [[LFString alloc] initWithString: template];

	/* Initialize the result */
	result = [[LFString alloc] init];

	/* Quote the username */
	quotedName = quoteForSearch(username);

	while ((part = [templateString substringToCString: userFormat]) != NULL) {
		LFString *temp;

		/* Append everything until the first %u */
		[result appendString: part];
		[part release];

		/* Append the username */
		[result appendString: quotedName];

		/* Move templateString past the %u */
		temp = [templateString substringFromCString: userFormat];
		[templateString release];
		templateString = temp;
	}

	[quotedName release];

	/* Append the remainder, if any */
	if (templateString) {
		[result appendString: templateString];
		[templateString release];
	}

	return (result);
}

#ifdef HAVE_PF
static BOOL pf_open(struct ldap_ctx *ctx) {
	LFString *tableName;
	TRLDAPGroupConfig *groupConfig;
	TREnumerator *groupIter;

	/* Acquire a reference to /dev/pf */
	ctx->pf = [[TRPacketFilter alloc] init];
	if (!ctx->pf) {
		/* /dev/pf could not be opened. Is it available? */
		[TRLog error: "Failed to open /dev/pf: %s", [TRPacketFilter strerror: errno]];
		ctx->pf = nil;
		return NO;
	}

	/* Clear out all referenced PF tables */
	if ((tableName = [ctx->config pfTable])) {
		if (![ctx->pf clearAddressesFromTable: tableName]) {
			[TRLog error: "Failed to clear packet filter table \"%s\": %s",
					[tableName cString], [TRPacketFilter strerror: errno]];
			goto error;
		}
	}

	if ([ctx->config ldapGroups]) {
		groupIter = [[ctx->config ldapGroups] objectEnumerator];
		while ((groupConfig = [groupIter nextObject]) != nil) {
			if ((tableName = [groupConfig pfTable]))
				if (![ctx->pf clearAddressesFromTable: tableName]) {
					[TRLog error: "Failed to clear packet filter table \"%s\": %s",
							[tableName cString], [TRPacketFilter strerror: errno]];
					[groupIter release];
					goto error;
				}
		}
		[groupIter release];
	}

	return YES;

error:
	[ctx->pf release];
	ctx->pf = NULL;
	return NO;
}
#endif /* HAVE_PF */

OPENVPN_EXPORT openvpn_plugin_handle_t
openvpn_plugin_open_v1(unsigned int *type, const char *argv[], const char *envp[]) {
	ldap_ctx *ctx = xmalloc(sizeof(ldap_ctx));
	ctx->config = [[LFAuthLDAPConfig alloc] initWithConfigFile: argv[1]];
	if (!ctx->config) {
		free(ctx);
		return (NULL);
	}

#ifdef HAVE_PF
	ctx->pf = NULL;
	/* Open reference to /dev/pf and clear out all of our PF tables */
	if ([ctx->config pfEnabled] && !pf_open(ctx)) {
		[ctx->config release];
		free(ctx);
		return (NULL);
	}
#endif


	*type = OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY) |
		OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_CLIENT_CONNECT) |
		OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_CLIENT_DISCONNECT);

	return (ctx);
}

OPENVPN_EXPORT void
openvpn_plugin_close_v1(openvpn_plugin_handle_t handle)
{
	ldap_ctx *ctx = handle;
	[ctx->config release];
#ifdef HAVE_PF
	if (ctx->pf)
		[ctx->pf release];
#endif
	free(ctx);
}

LFLDAPConnection *connect_ldap(LFAuthLDAPConfig *config) {
	LFLDAPConnection *ldap;
	LFString *value;

	/* Initialize our LDAP Connection */
	ldap = [[LFLDAPConnection alloc] initWithURL: [config url] timeout: [config timeout]];
	if (!ldap) {
		[TRLog error: "Unable to open LDAP connection to %s\n", [[config url] cString]];
		return nil;
	}

	/* Referrals */
	if ([config referralEnabled]) {
		if (![ldap setReferralEnabled: YES])
			goto error;
	} else {
		if (![ldap setReferralEnabled: NO])
			goto error;
	}

	/* Bind if requested */
	if ([config bindDN]) {
		if (![ldap bindWithDN: [config bindDN] password: [config bindPassword]]) {
			[TRLog error: "Unable to bind as %s", [[config bindDN] cString]];
			goto error;
		}
	}

        /* Certificate file */
	if ((value = [config tlsCACertFile])) 
		if (![ldap setTLSCACertFile: value])
			goto error;

	/* Certificate directory */
	if ((value = [config tlsCACertDir])) 
		if (![ldap setTLSCACertDir: value])
			goto error;

	/* Client Certificate Pair */
	if ([config tlsCertFile] && [config tlsKeyFile])
		if(![ldap setTLSClientCert: [config tlsCertFile] keyFile: [config tlsKeyFile]])
			goto error;

	/* Cipher suite */
	if ((value = [config tlsCipherSuite]))
		if(![ldap setTLSCipherSuite: value])
			goto error;

	/* Start TLS */
	if ([config tlsEnabled])
		if (![ldap startTLS])
			goto error;

	return ldap;

error:
	[ldap release];
	return nil;
}

static TRLDAPEntry *find_ldap_user (LFLDAPConnection *ldap, LFAuthLDAPConfig *config, const char *username) {
	LFString		*searchFilter;
	TRArray			*ldapEntries;
	TRLDAPEntry		*result = nil;

	/* Assemble our search filter */
	searchFilter = createSearchFilter([config searchFilter], username);

	/* Search! */
	ldapEntries = [ldap searchWithFilter: searchFilter
		scope: LDAP_SCOPE_SUBTREE
		baseDN: [config baseDN]
		attributes: NULL];
	[searchFilter release];
	if (!ldapEntries)
		return nil;
	if ([ldapEntries count] < 1) {
		[ldapEntries release];
		return nil;
	}
		
	/* The specified search string may (but should not) return more than one entry.
	 * We ignore any extras. */
	result = [[ldapEntries lastObject] retain];

	[ldapEntries release];

	return result;
}


static BOOL auth_ldap_user(LFLDAPConnection *ldap, LFAuthLDAPConfig *config, TRLDAPEntry *ldapUser, const char *password) {
	LFLDAPConnection *authConn;
	LFString *passwordString;
	BOOL result = NO;

	/* Create a second connection for binding */
	authConn = connect_ldap(config);
	if (!authConn) {
		return NO;
	}

	/* Allocate the string to pass to bindWithDN */
	passwordString = [[LFString alloc] initWithCString: password];

	if ([authConn bindWithDN: [ldapUser dn] password: passwordString]) {
		result = YES;
	}

	[passwordString release];
	[authConn release];

	return result;
}

static TRLDAPGroupConfig *find_ldap_group(LFLDAPConnection *ldap, LFAuthLDAPConfig *config, TRLDAPEntry *ldapUser) {
	TREnumerator *groupIter;
	TRLDAPGroupConfig *groupConfig;
	TRArray *ldapEntries;
	TREnumerator *entryIter;
	TRLDAPEntry *entry;
	TRLDAPGroupConfig *result = nil;

	/*
	 * Groups are loaded into the array in the order that they are listed
	 * in the configuration file, and we are expected to perform
	 * "first match". Thusly, we'll walk the stack from the bottom up.
	 */
	groupIter = [[config ldapGroups] objectReverseEnumerator];
	while ((groupConfig = [groupIter nextObject]) != nil) {
		/* Search for the group */
		ldapEntries = [ldap searchWithFilter: [groupConfig searchFilter]
			scope: LDAP_SCOPE_SUBTREE
			baseDN: [groupConfig baseDN]
			attributes: NULL];

		/* Error occured, all stop */
		if (!ldapEntries)
			break;

		/* Iterate over the returned entries */
		entryIter = [ldapEntries objectEnumerator];
		while ((entry = [entryIter nextObject]) != nil) {
			if ([ldap compareDN: [entry dn] withAttribute: [groupConfig memberAttribute] value: [ldapUser dn]]) {
				/* Group match! */
				result = groupConfig;
			}
		}
		[entryIter release];
		[ldapEntries release];
		if (result)
			break;
	}

	[groupIter release];
	return result;
}


static char hexchars[] = "0123456789abcdef";
static char * urlencode(const char *str) {
    char * result = malloc(strlen(str) * 3 + 1);
    char * p = result;
    while (*str) {
        if (isalnum(*str) || *str == '-' || *str == '_' || *str == '.' || *str == '~') {
            *p ++ = *str;
        } else if (*str == ' ') {
            *p ++ = '+';
        } else {
            *p ++ = '%';
            *p ++ = hexchars[(*str >> 4) & 0xff];
            *p ++ = hexchars[*str & 0xff];
        }
        str ++;
    }
    *p = '\0';
    return result;
}

static char * urldecode(const char *str) {
    char * result = malloc(strlen(str) + 1);
    char * p = result;
    while (*str) {
        if (*str == '%') {
            if (str[1] && str[2]) {
                *p = (isdigit(str[1]) ? (str[1] - '0') : (tolower(str[1]) - 'a' + 10)) << 4;
                *p = isdigit(str[2]) ? (str[2] - '0') : (tolower(str[2]) - 'a' + 10);
                str += 2;
                p ++;
            }
        } else if (*str == '+') { 
            *p ++ = ' ';
        } else {
            *p ++ = *str;
        }
        str ++;
    }
    *p = '\0';
    return result;
}

static int str_cmp(const void * a, const void * b) {
    return strcmp((char*) a, (char*) b);
}

static char * compute_sign(const char * url, const char * secret, const char * username,
        const char * algorithm, const char * digits, const char * issuer, const char * type,
        const char * extra, const int period, const time_t now, char * sign) {

    int i, count;
    char * extra2, ** keys, *p;
    char buffer[4096], tmp[4096], timestr[32] = {0};

    snprintf(timestr, sizeof(timestr), "%ld", now);
    if(extra == NULL) {
        snprintf(buffer, sizeof(buffer), "%saccount=%s&algorithm=%s&digits=%s&issuer=%s&period=%d&type=%s%s",
                secret, username, algorithm, digits, issuer, period, type, timestr);
    } else {
        extra2 = urldecode(extra);
        snprintf(tmp, sizeof(tmp), "account=%s&algorithm=%s&digits=%s&issuer=%s&period=%d&type=%s&%s",
                username, algorithm, digits, issuer, period, type, extra2);
        free(extra2);

        keys = (char **) malloc(MAX_API_PARAMS_COUNT * sizeof(char*));
        if (keys == NULL) {
            [TRLog error: "Cannot allocate %d memory for keys - OpenVPN LDAP Plugin", MAX_API_PARAMS_COUNT * sizeof(char*)];
            return NULL;
        }

        i = 1;
        p = *keys = tmp;
        while (* ++p) {
            if (*(p - 1) == '&') {
                *(keys + i ++) = p;
                *(p - 1) = '\0';
            }
        }
        count = i;
        qsort(keys, count, sizeof(char*), str_cmp);
        memset(buffer, 0, sizeof(buffer));
        strcat(buffer, secret);
        for(i = 0; i < count; i ++) {
            if(i > 0) {
                strcat(buffer, "&");
            }
            strcat(buffer, keys[i]);
        }
        strcat(buffer, timestr);

        if(keys) {
            free(keys);
            keys = NULL;
        }
    }

    [TRLog debug: "String to be signed is '%s' - OpenVPN LDAP Plugin", buffer];

    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256_CTX sha256;
    SHA256_Init(&sha256);
    SHA256_Update(&sha256, buffer, strlen(buffer));
    SHA256_Final(hash, &sha256);

    for (i = 0; i < SHA256_DIGEST_LENGTH; i++) {
        sprintf(sign + (i * 2), "%02x", hash[i]);
    }
    sign[64] = '\0';
    strcat(sign, timestr);

    [TRLog debug: "String after signed is '%s' - OpenVPN LDAP Plugin", sign];

    return sign;
}

static size_t write_data(void * buffer, size_t size, size_t nmemb, void * userdata) {
    size_t realsize;

    realsize = size * nmemb;
    realsize = realsize >= MAX_CURL_RESULT_LENGTH ? MAX_CURL_RESULT_LENGTH - 1 : realsize;
    memcpy(userdata, buffer, realsize);

    return realsize;
}

static bool generate_url(LFAuthLDAPConfig * config,
        const char * username, const char * digits, char *result, size_t len) {
    int period;
    BOOL signEnabled;
    const LFString *sApi, *sSecret, *sType, *sAlgorithm, *sIssuer;
    const char *api, *secret, *type, *algorithm, *issuer;
    char *username2, *algorithm2, *issuer2, *type2;
    char *url, *extra, sign[100] = {0};
    time_t now;

    sApi = [config oathApi];
    sSecret = [config oathSecret];

    sIssuer = [config oathIssuer];
    sType = [config oathType];
    sAlgorithm = [config oathAlgorithm];

    period = [config oathPeriod];
    signEnabled = [config oathSignEnabled];

    period = period > 0 ? period : DEFAULT_OATH_PEROID;

    api = [sApi cString];
    secret = [sSecret cString];
    issuer = sIssuer == NULL ? DEFAULT_OATH_ISSUER : [sIssuer cString];
    type = sType == NULL ? DEFAULT_OATH_TYPE : [sType cString];
    algorithm = sAlgorithm == NULL ? DEFAULT_OATH_ALGORITHM : [sAlgorithm cString];

    username2 = urlencode(username);
    algorithm2 = urlencode(algorithm);
    issuer2 = urlencode(issuer);
    type2 = urlencode(type);

    url = xstrdup(api);
    extra = strchr(url, '?');
    if (extra != NULL) {
        * extra ++ = '\0';
    }
    if (extra != NULL && *extra == '\0') {
        extra = NULL; 
    }

    now = time(NULL);
    if (signEnabled){
        compute_sign(url, secret, username, algorithm, digits, issuer, type, extra, period, now, sign);
    }

    // account=xxxx
    // algorithm=sha1
    // digits=123456
    // issuer=xxxxxx
    // period=30
    // type=totp
    //
    // sign=xxxx
    snprintf(result, len, "%s%caccount=%s&algorithm=%s&digits=%s&issuer=%s&period=%d&type=%s&sign=%s%s%s",
            url, '?', username2, algorithm2, digits, issuer2, period,
            type2, strlen(sign) ? sign : "", extra ? "&" : "", extra ? extra : "");

    if(username2) free(username2);
    if(algorithm2) free(algorithm2);
    if(issuer2) free(issuer2);
    if(type2) free(type2);

    return true;
}

static bool is_digits(const char * digits) {
    size_t i, len = strlen(digits);
    for(i = 0; i < len; i ++) {
        if (digits[i] < '0' || digits[i] > '9') {
            return false;
        }
    }
    return true;
}

static int handle_auth_user_oath_verify(LFAuthLDAPConfig *config, const char * username, const char * digits) {
    long code;
    CURLcode res;
    int timeout, connectTimeout, digitsLength, ret;
    char buffer[4096] = {0}, result[MAX_CURL_RESULT_LENGTH] = {0};

    digitsLength = [config oathDigitsLength];
    digitsLength = digitsLength < DEFAULT_OATH_DIGITS_LENGTH ? DEFAULT_OATH_DIGITS_LENGTH : digitsLength;

    if (!is_digits(digits)) {
        [TRLog debug: "Incorrect remote password - OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY)."];
        return (OPENVPN_PLUGIN_FUNC_ERROR);
    }

    timeout = [config oathTimeout];
    connectTimeout = [config oathConnectTimeout];

    timeout = timeout > 0 ? timeout : DEFAULT_OATH_TIMEOUT;
    connectTimeout = connectTimeout > 0 ? connectTimeout : DEFAULT_OATH_CONNECT_TIMEOUT;

    if (!generate_url(config, username, digits, buffer, sizeof(buffer))) {
        [TRLog error: "Generate url failed - OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY)."];
        return OPENVPN_PLUGIN_FUNC_ERROR;
    }

    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        [TRLog error: "Init curl failed - OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY)."];
        return OPENVPN_PLUGIN_FUNC_ERROR;
    }

    curl_easy_setopt(curl, CURLOPT_URL, buffer);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_data);   
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &result);   
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 3);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 3);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "openvpn-" PACKAGE_NAME "/" PACKAGE_VERSION);
    res = curl_easy_perform(curl);
    ret = OPENVPN_PLUGIN_FUNC_SUCCESS;
    if(res != CURLE_OK) {
        [TRLog error: "Request %s failed, and return %d - OpenVPN LDAP Plugin "
            "(OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY).", buffer, res];
        ret = OPENVPN_PLUGIN_FUNC_ERROR;
    } else if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code) == CURLE_OK) {    
        if(strncmp(result, "true", sizeof("true") - 1) == 0) {
            ret = OPENVPN_PLUGIN_FUNC_SUCCESS;
        } else {
            [TRLog error: "Request %s success, response code is %d, result is '%s' - OpenVPN LDAP Plugin "
                "(OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY).", buffer, code, result];
            ret = OPENVPN_PLUGIN_FUNC_ERROR;
        }
    } else {
        [TRLog error: "Request %s success, but get response code failed - OpenVPN LDAP Plugin "
            "(OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY).", buffer];
        ret = OPENVPN_PLUGIN_FUNC_ERROR;
    }
    curl_easy_cleanup(curl);

    return ret;
}

/*! Handle user authentication. */
static int handle_auth_user_pass_verify(ldap_ctx *ctx, LFLDAPConnection *ldap, TRLDAPEntry *ldapUser, const char *password) {
	TRLDAPGroupConfig *groupConfig;

	/* Authenticate the user */
	if (!auth_ldap_user(ldap, ctx->config, ldapUser, password)) {
		[TRLog error: "Incorrect password supplied for LDAP DN \"%s\".", [[ldapUser dn] cString]];
		return (OPENVPN_PLUGIN_FUNC_ERROR);
	}

	/* User authenticated, find group, if any */
	if ([ctx->config ldapGroups]) {
		groupConfig = find_ldap_group(ldap, ctx->config, ldapUser);
		if (!groupConfig && [ctx->config requireGroup]) {
			/* No group match, and group membership is required */
			return OPENVPN_PLUGIN_FUNC_ERROR;
		} else {
			/* Group match! */
			return OPENVPN_PLUGIN_FUNC_SUCCESS;
		}
	} else {
		// No groups, user OK
		return OPENVPN_PLUGIN_FUNC_SUCCESS;
	}

	/* Never reached */
	return OPENVPN_PLUGIN_FUNC_ERROR;
}

#ifdef HAVE_PF
/* Add (or remove) the remote address */
static BOOL pf_client_connect_disconnect(struct ldap_ctx *ctx, LFString *tableName, const char *remoteAddress, BOOL connecting) {
	LFString *addressString;
	TRPFAddress *address;

	addressString = [[LFString alloc] initWithCString: remoteAddress];
	address = [[TRPFAddress alloc] initWithPresentationAddress: addressString];
	[addressString release];
	if (connecting) {
		[TRLog debug: "Adding address \"%s\" to packet filter table \"%s\".", remoteAddress, [tableName cString]];
		if (![ctx->pf addAddress: address toTable: tableName]) {
			[TRLog error: "Failed to add address \"%s\" to table \"%s\": %s",
					remoteAddress, [tableName cString], [TRPacketFilter strerror: errno]];
			[address release];
			return NO;
		}
	} else {
		[TRLog debug: "Removing address \"%s\" from packet filter table \"%s\".", remoteAddress, [tableName cString]];
		if (![ctx->pf deleteAddress: address fromTable: tableName]) {
			[TRLog error: "Failed to remove address \"%s\" from table \"%s\": %s",
					remoteAddress, [tableName cString], [TRPacketFilter strerror: errno]];
			[address release];
			return NO;
		}
	}
	[address release];

	return YES;
}
#endif /* HAVE_PF */


/*! Handle both connection and disconnection events. */
static int handle_client_connect_disconnect(ldap_ctx *ctx, LFLDAPConnection *ldap, TRLDAPEntry *ldapUser, const char *remoteAddress, BOOL connecting) {
	TRLDAPGroupConfig *groupConfig = nil;
#ifdef HAVE_PF
	LFString *tableName = nil;
#endif

	/* Locate the group (config), if any */
	if ([ctx->config ldapGroups]) {
		groupConfig = find_ldap_group(ldap, ctx->config, ldapUser);
		if (!groupConfig && [ctx->config requireGroup]) {
			[TRLog error: "No matching LDAP group found for user DN \"%s\", and group membership is required.", [[ldapUser dn] cString]];
			/* No group match, and group membership is required */
			return OPENVPN_PLUGIN_FUNC_ERROR;
		}
	}

#ifdef HAVE_PF
	/* Grab the requested PF table name, if any */
	if (groupConfig) {
		tableName = [groupConfig pfTable];
	} else {
		tableName = [ctx->config pfTable];
	}

	if (tableName)
		if (!pf_client_connect_disconnect(ctx, tableName, remoteAddress, connecting))
			return OPENVPN_PLUGIN_FUNC_ERROR;
#endif /* HAVE_PF */

	return OPENVPN_PLUGIN_FUNC_SUCCESS;
}



OPENVPN_EXPORT int
openvpn_plugin_func_v1(openvpn_plugin_handle_t handle, const int type, const char *argv[], const char *envp[]) {
    size_t digitsLength, passwordLength;
    char *digits, *realPassword;
	const char *username, *password, *remoteAddress;
	ldap_ctx *ctx = handle;
	LFLDAPConnection *ldap = nil;
	TRLDAPEntry *ldapUser = nil;
	int ret = OPENVPN_PLUGIN_FUNC_ERROR;

	username = get_env("username", envp);
	password = get_env("password", envp);
	remoteAddress = get_env("ifconfig_pool_remote_ip", envp);

	/* At the very least, we need a username to work with */
	if (!username) {
		[TRLog debug: "No remote username supplied to OpenVPN LDAP Plugin."];
		return (OPENVPN_PLUGIN_FUNC_ERROR);
	}

	/* Create an LDAP connection */
	if (!(ldap = connect_ldap(ctx->config))) {
		[TRLog error: "LDAP connect failed."];
		return (OPENVPN_PLUGIN_FUNC_ERROR);
	}

	/* Find the user record */
	ldapUser = find_ldap_user(ldap, ctx->config, username);
	if (!ldapUser) {
		/* No such user. */
		[TRLog warning: "LDAP user \"%s\" was not found.", username];
		ret = OPENVPN_PLUGIN_FUNC_ERROR;
		goto cleanup;
	}

	switch (type) {
		/* Password Authentication */
		case OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY:
            digits = NULL;
            realPassword = password;
            if (password && [ctx->config oathEnabled]) {
                digitsLength = [ctx->config oathDigitsLength];
                digitsLength = digitsLength < DEFAULT_OATH_DIGITS_LENGTH ? DEFAULT_OATH_DIGITS_LENGTH : digitsLength;
                passwordLength = strlen(password);
                if (passwordLength <= digitsLength) {
                    [TRLog debug: "Remote password is too simple to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY)."];
                    ret = OPENVPN_PLUGIN_FUNC_ERROR;
                    break;
                }
                digits = password + passwordLength - digitsLength;
                realPassword = xstrndup(password, passwordLength - digitsLength);
            }
			if (!realPassword) {
				[TRLog debug: "No remote password supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY)."];
				ret = OPENVPN_PLUGIN_FUNC_ERROR;
			} else {
				ret = handle_auth_user_pass_verify(ctx, ldap, ldapUser, realPassword);
			}

            if (ret == OPENVPN_PLUGIN_FUNC_SUCCESS && digits) {
                ret = handle_auth_user_oath_verify(ctx->config, username, digits); 
            }

            if (realPassword != password) {
                free(realPassword);
            }
			break;
		/* New connection established */
		case OPENVPN_PLUGIN_CLIENT_CONNECT:
			if (!remoteAddress) {
				[TRLog debug: "No remote address supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_CLIENT_CONNECT)."];
				ret = OPENVPN_PLUGIN_FUNC_ERROR;
			} else {
				ret = handle_client_connect_disconnect(ctx, ldap, ldapUser, remoteAddress, YES);
			}
			break;
		case OPENVPN_PLUGIN_CLIENT_DISCONNECT:
			if (!remoteAddress) {
				[TRLog debug: "No remote address supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_CLIENT_DISCONNECT)."];
				ret = OPENVPN_PLUGIN_FUNC_ERROR;
			} else {
				ret = handle_client_connect_disconnect(ctx, ldap, ldapUser, remoteAddress, NO);
			}
			break;
		default:
			[TRLog debug: "Unhandled plugin type in OpenVPN LDAP Plugin (type=%d)", type];
			ret = OPENVPN_PLUGIN_FUNC_ERROR;
			break;
	}

cleanup:
	if (ldapUser)
		[ldapUser release];
	if (ldap)
		[ldap release];
	return (ret);
}
