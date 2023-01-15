module github;

import std.algorithm;
import std.conv;
import std.digest.md;
import std.file;
import std.string;
import std.utf;

import ae.net.http.common;
import ae.net.ietf.url;
import ae.net.ietf.headers;
import ae.sys.data;
import ae.sys.file;
import ae.sys.net;
import ae.utils.digest;
import ae.utils.json;

import common : config, log;

struct CacheEntry
{
	string[string] headers;
	string data;
}

// Shim for ae.sys.net - TODO refactor away
void httpRequest(HttpRequest request, void delegate(HttpResponse response, string disconnectReason) resultHandler)
{
	HttpResponse response;
	try
		response = net.httpRequest(request);
	catch (Exception e)
	{
		resultHandler(null, e.msg);
		return;
	}
	resultHandler(response, null);
}

// ditto
void httpRequest(HttpRequest request, void delegate(Data) resultHandler, void delegate(string) errorHandler, int redirectCount = 0)
{
	void responseHandler(HttpResponse response, string disconnectReason)
	{
		if (!response)
			if (errorHandler)
				errorHandler(disconnectReason);
			else
				throw new Exception(disconnectReason);
		else
		if (response.status >= 300 && response.status < 400 && "Location" in response.headers)
		{
			if (redirectCount == 15)
				throw new Exception("HTTP redirect loop: " ~ request.url);
			request.resource = applyRelativeURL(request.url, response.headers["Location"]);
			if (response.status == HttpStatusCode.SeeOther)
			{
				request.method = "GET";
				request.data = null;
			}
			httpRequest(request, resultHandler, errorHandler, redirectCount+1);
		}
		else
			if (errorHandler)
				try
					resultHandler(response.getContent());
				catch (Exception e)
					errorHandler(e.msg);
			else
				resultHandler(response.getContent());
	}

	httpRequest(request, &responseHandler);
}

void githubQuery(string url, void delegate(Headers, string) handleData, void delegate(string) handleError)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.headers["Authorization"] = "token " ~ config.token;

	auto cacheFileName = "cache/" ~ getDigestString!MD5(url).toLower();

	CacheEntry cacheEntry;
	if (cacheFileName.exists)
	{
		cacheEntry = jsonParse!CacheEntry(readText(cacheFileName));

		if (auto p = "ETag" in cacheEntry.headers)
			request.headers["If-None-Match"] = *p;
		if (auto p = "Last-Modified" in cacheEntry.headers)
			request.headers["If-Modified-Since"] = *p;
	}

	log("Getting URL " ~ url);

	void resultHandler(HttpResponse response, string disconnectReason)
	{
		if (!response)
			handleError("Error with URL " ~ url ~ ": " ~ disconnectReason);
		else
		{
			if (response.status == HttpStatusCode.NotModified)
			{
				log(" > Cache hit");
				handleData(Headers(cacheEntry.headers), cacheEntry.data);
			}
			else
			if (response.status == HttpStatusCode.OK)
			{
				log(" > Cache miss");
				{
					scope(failure) log(response.headers.text);
					cacheEntry.headers = response.headers.to!(string[string]);
				}
				auto data = (cast(char[])response.getContent().contents).idup;
				cacheEntry.data = data;
				ensurePathExists(cacheFileName);
				write(cacheFileName, toJson(cacheEntry));
				handleData(response.headers, data);
			}
			else
			if (response.status >= 300 && response.status < 400 && "Location" in response.headers)
			{
				auto location = response.headers["Location"];
				log(" > Redirect: " ~ location);
				request.resource = applyRelativeURL(request.url, location);
				if (response.status == HttpStatusCode.SeeOther)
				{
					request.method = "GET";
					request.data = null;
				}
				httpRequest(request, &resultHandler);
			}
			else
				handleError("Error with URL " ~ url ~ ": " ~ text(response.status));
		}
	}
	httpRequest(request, &resultHandler);
}

string githubQuery(string url)
{
	string result;

	githubQuery(url,
		(Headers headers, string dataReceived)
		{
			result = dataReceived;
		},
		(string error)
		{
			throw new Exception(error);
		}
	);

	// socketManager.loop();
	return result;
}

import std.json;

JSONValue[] githubPagedQuery(string url)
{
	JSONValue[] result;

	void getPage(string url)
	{
		githubQuery(url,
			(Headers headers, string data)
			{
				result ~= data.parseJSON().array;
				auto links = parseLinks(headers.get("Link", null));
				if ("next" in links)
					getPage(links["next"]);
			},
			(string error)
			{
				throw new Exception(error);
			}
		);
	}

	getPage(url);
	// socketManager.loop();
	return result;
}

/// Parse a "Link" header.
string[string] parseLinks(string s)
{
	string[string] result;
	auto items = s.split(", "); // Hacky but should never occur inside an URL or "rel" value
	foreach (item; items)
	{
		auto parts = item.split("; "); // ditto
		string url; string[string] args;
		foreach (part; parts)
		{
			if (part.startsWith("<") && part.endsWith(">"))
				url = part[1..$-1];
			else
			{
				auto ps = part.findSplit("=");
				auto key = ps[0];
				auto value = ps[2];
				if (value.startsWith('"') && value.endsWith('"'))
					value = value[1..$-1];
				args[key] = value;
			}
		}
		result[args.get("rel", null)] = url;
	}
	return result;
}

unittest
{
	auto header = `<https://api.github.com/repositories/1257070/pulls?per_page=100&page=2>; rel="next", ` ~
		`<https://api.github.com/repositories/1257070/pulls?per_page=100&page=3>; rel="last"`;
	assert(parseLinks(header) == [
		"next" : "https://api.github.com/repositories/1257070/pulls?per_page=100&page=2",
		"last" : "https://api.github.com/repositories/1257070/pulls?per_page=100&page=3",
	]);
}

string githubPost(string url, string jsonData)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.method = "POST";
	request.headers["Authorization"] = "token " ~ config.token;
	request.headers["Content-Type"] = "application/json";
	request.data = DataVec(Data(jsonData));

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

	// socketManager.loop();
	return result;
}
