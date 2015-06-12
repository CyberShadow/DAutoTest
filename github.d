module github;

import std.conv;
import std.digest.md;
import std.file;
import std.string;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.common;
import ae.sys.file;
import ae.utils.digest;
import ae.utils.json;

import common : config, log;

struct CacheEntry
{
	string etag, lastModified, data;
}

void githubQuery(string url, void delegate(string) handleData, void delegate(string) handleError)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.headers["Authorization"] = "token " ~ config.token;

	auto cacheFileName = "cache/" ~ getDigestString!MD5(url).toLower();

	CacheEntry cacheEntry;
	if (cacheFileName.exists)
	{
		cacheEntry = jsonParse!CacheEntry(readText(cacheFileName));

		if (cacheEntry.etag)
			request.headers["If-None-Match"] = cacheEntry.etag;
		if (cacheEntry.lastModified)
			request.headers["If-Modified-Since"] = cacheEntry.lastModified;
	}

	log("Getting URL " ~ url);
	httpRequest(request,
		(HttpResponse response, string disconnectReason)
		{
			if (!response)
				handleError("Error with URL " ~ url ~ ": " ~ disconnectReason);
			else
			{
				string s;
				if (response.status == HttpStatusCode.NotModified)
				{
					log(" > Cache hit");
					s = cacheEntry.data;
					handleData(s);
				}
				else
				if (response.status == HttpStatusCode.OK)
				{
					log(" > Cache hit");
					scope(failure) log(response.headers.text);
					s = (cast(char[])response.getContent().contents).idup;
					cacheEntry.etag = response.headers.get("ETag", null);
					cacheEntry.lastModified = response.headers.get("Last-Modified", null);
					cacheEntry.data = s;
					ensurePathExists(cacheFileName);
					write(cacheFileName, toJson(cacheEntry));
					handleData(s);
				}
				else
					handleError("Error with URL " ~ url ~ ": " ~ text(response.status));
			}
		});
}

string githubQuery(string url)
{
	string result;

	githubQuery(url,
		(string dataReceived)
		{
			result = dataReceived;
		},
		(string error)
		{
			throw new Exception(error);
		}
	);

	socketManager.loop();
	return result;
}

string githubPost(string url, string jsonData)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.method = "POST";
	request.headers["Authorization"] = "token " ~ config.token;
	request.headers["Content-Type"] = "application/json";
	request.data = [Data(jsonData)];

	string result;

	httpRequest(request,
		(Data data)
		{
			result = (cast(char[])data.contents).idup;
			std.utf.validate(result);
		},
		(string error)
		{
			throw new Exception(error);
		});

	socketManager.loop();
	return result;
}
