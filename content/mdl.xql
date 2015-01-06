xquery version "3.0";

(:
 * This module provides model-based querying for XML
 :)

module namespace mdl="http://lagua.nl/lib/mdl";

declare namespace request="http://exist-db.org/xquery/request";
declare namespace response="http://exist-db.org/xquery/response";
declare namespace sm="http://exist-db.org/xquery/securitymanager";

import module namespace json="http://www.json.org";
import module namespace xmldb="http://exist-db.org/xquery/xmldb";
import module namespace xqjson="http://xqilla.sourceforge.net/lib/xqjson";
import module namespace rql="http://lagua.nl/lib/rql" at "rql.xql";

declare variable $mdl:maxLimit := 100;

declare function mdl:check-html($node,$accept) {
	if(exists($node) and matches($accept,"application/[json|javascript]")) then
		element { name($node) } {
			$node/@*,
			for $x in $node/* return
				if($x/body) then
					element { name($x) } { util:serialize($x/body,"method=html media-type=text/html") }
				else
					$x
		}
	else
		$node 
};

declare %private function mdl:replace-vars($str as xs:string, $node as element()) {
	if($str) then
		string-join(
			for $x in analyze-string($str, "\{([^}]*)\}")/* return
				if(local-name($x) eq "non-match") then
					$x
				else
					for $g in $x/fn:group
						return $node/*[local-name() eq $g]
		)
	else
		""
};

declare %private function mdl:get-model-from-path($path) {
	let $parts := tokenize($path,"/")
	let $last := $parts[last()]
	let $parts := remove($parts,count($parts))
	return
		if($last!="") then
			$last
		else if(count($parts)>0) then
			mdl:get-model-from-path(string-join($parts,"/"))
		else
			()
};

declare function mdl:resolve-links($node as element(), $schema as element()?, $store as xs:string, $schemastore as xs:string) as element() {
	if($schema) then
		element { name($node) } {
			$node/@*,
			$node/*[not(name() = $schema/links/rel/text())],
			for $l in $schema/links return
				let $href := tokenize($l/href,"\?")
				let $uri := mdl:replace-vars(string($href[1]),$node)
				let $query-string := mdl:replace-vars(string($href[2]),$node)
				return
					if($l/resolution eq "lazy") then
						let $href := 
							if($query-string) then
								$uri || "?" || $query-string
							else
								$uri
						return
							element { $l/rel } {
								element { "_ref" } { $href }
							}
					else if($l/resolution eq "eager") then
						let $q := rql:parse($query-string,())
						return element { $l/rel } {
							let $href := resolve-uri($uri,$store || "/")
							let $lmodel := mdl:get-model-from-path($href)
							let $lschema := doc($schemastore || "/" || $lmodel || ".xml")/root
							let $data := rql:sequence(collection($href)/root,$q,500)
							return
								if(count($data)) then
									for $x in $data return
										element {"json:value"} {
											attribute {"json:array"} {"true"},
											mdl:resolve-links($x,$lschema,$href,$schemastore)/node()
										}
								else
									element {"json:value"} {
										attribute {"json:array"} {"true"}
									}
						}
					else
						()
		}
	else
		$node
};

(: fill in defaults, infer types :)
(: TODO basic validation :)
declare function mdl:from-schema($node as element()*, $schema as element()?) {
	if($schema) then
		let $props := for $p in $node/* return name($p)
		let $defaults :=
			for $p in $schema/properties/* return
				if(name($p) = $props) then
					()
				else
					if($p/default) then
						element { name($p) } {
							if($p/type eq "string") then
								()
							else
								attribute { "json:literal"} { "true" },
							if($p/type eq "string" and $p/format eq "date-time" and $p/default eq "now()") then
								current-dateTime()
							else if($p/type = ("array","object")) then
								$p/default/*
							else
								$p/default/text()
						}
					else
						()
		let $props := for $p in $schema/properties/* return name($p)
		let $data := for $p in $node/* return
			if(name($p) = $props) then
				let $s := $schema/properties/*[name(.) = name($p)]
				return
					if($s/type = ("boolean","number","integer","null")) then
						element { name($p) } {
							attribute {"json:literal"} { "true" },
							$p/text()
						}
					else
						$p
			else
				$p
		return element { name ($node) } {
			$data,
			$defaults
		}
	else
		$node
};

(: writes increment value to schema :)
declare function mdl:get-next-id($schema as element()?,$schemastore as xs:string) {
	if($schema) then
		let $key := $schema/properties/*[primary and auto_increment]
		let $id := 
			if($key) then
				string($key/auto_increment)
			else
				()
		let $null :=
			if($key) then
				let $schema :=
					element root {
						$schema/@*,
						element properties {
							for $p in $schema/properties/* return
								if($p=$key) then
									element {name($p)} {
										$p/@*,
										$p/*[name(.) != "auto_increment"],
										element auto_increment {
											$p/auto_increment/@*,
											number($p/auto_increment) + 1
										}
									}
								else
									$p
						},
						$schema/*[name(.) != "properties"]
					}
				return xmldb:store($schemastore,$schema/id || ".xml",$schema)
			else
				()
		return $id
	else
		()
};

declare function mdl:remove-links($node as element(),$schema as element()?) {
	if($schema) then
		let $links := for $l in $schema/links return string($l/rel)
		return
			element { name($node) } {
				$node/@*,
				for $x in $node/node() return
					if(name($x) = $links) then
						()
					else
						$x
			}
	else
		$node
};

declare variable $mdl:describe := map {
	"writable" := function($node, $uri) {
		element _writable {
			attribute json:literal { "true" },
			sm:has-access($uri, "w")
		}
	}
};

declare function mdl:add-metadata($node as element(),$store as xs:string, $describe as xs:string) {
	let $meta := tokenize($describe,"\s*,\s*")
	let $uri := xs:anyURI($store || "/" || $node/id || ".xml")
	return
		if(doc-available($uri)) then
			element { name($node) } {
					$node/@*,
					$node/*,
					for $m in $meta return
						if(map:contains($mdl:describe,$m)) then
							map:get($mdl:describe,$m)($node,$uri)
						else
							()
				}
		else
			$node
};

declare function mdl:get-schema($schemastore as xs:string, $model as xs:string) {
	let $schemaname := $model || ".xml"
	let $schemadoc := $schemastore || "/" || $schemaname
	return
		if(doc-available($schemadoc)) then
			doc($schemadoc)/root
		else
			()
};

declare function mdl:request() {
	mdl:request("/db/data")
};

declare function mdl:request($dataroot as xs:string) {
	let $domain := request:get-header("content-domain")
	let $domain := 
		if($domain) then
			$domain
		else
			request:get-server-name()
	return mdl:request($dataroot,$domain)
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string) {
	mdl:request($dataroot,$domain,request:get-parameter("model",""))
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string) {
	mdl:request($dataroot,$domain,$model,request:get-parameter("id","")[1])
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,string(request:get-query-string()))
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,$query-string,request:get-method())
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string,$method as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,$query-string,$method,request:get-header("Accept"))
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string,$method as xs:string,$accept as xs:string) {
	let $data := 
		if($method = ("PUT","POST")) then
			let $data := request:get-data()
			return
				if($data) then
					mdl:to-plain-xml(xqjson:parse-json(util:binary-to-string($data)))
				else
					<root/>
		else
			<root/>
	return mdl:request($dataroot,$domain,$model,$id,$query-string,$method,$accept,$data)
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string,$method as xs:string,$accept as xs:string,$data as node()) {
	mdl:request($dataroot,$domain,$model,$id,$query-string,$method,$accept,$data,false())
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string,$method as xs:string,$accept as xs:string,$data as node(),$forcexml as xs:boolean) {
	let $describe := string(request:get-header("describe"))
	return mdl:request($dataroot,$domain,$model,$id,$query-string,$method,$accept,$data,$forcexml,$describe)
};

declare function mdl:get($collection as xs:string, $id as xs:string, $directives as map) {
	let $node := doc($collection || "/" || $id || ".xml")/root
	let $describe := $directives("describe")
	let $accept := $directives("accept")
	let $model := $directives("model")
	let $schemastore := $directives("schemastore")
	let $schema := mdl:get-schema($schemastore, $model)
	return
		if($node) then
			mdl:check-html(mdl:resolve-links(mdl:add-metadata($node,$collection,$describe),$schema,$collection,$schemastore),$accept)
		else
			<http:response status="404" msg="Error: {$model}/{$id} not found"/>
};

declare function mdl:query($collection as xs:string, $query-string as xs:string, $directives as map) {
	let $range := $directives("range")
	let $describe := $directives("describe")
	let $accept := $directives("accept")
	let $model := $directives("model")
	let $schemastore := $directives("schemastore")
	let $rqlquery := rql:parse($query-string)
	let $rqlxq := rql:to-xq($rqlquery)
	return
		if($query-string != "" or $range or exists($rqlxq("limit")) or sm:is-authenticated()) then
			let $schema := mdl:get-schema($schemastore, $model)
			let $maxLimit :=
				if($schema/maxCount) then
					number($schema/maxCount)
				else
					$mdl:maxLimit
			let $items := collection($collection)/root
			let $totalcount := count($items)
			(: filter :)
			let $items := rql:xq-filter($items,$rqlxq("filter"),$rqlxq("aggregate"))
			return
				if($rqlxq("aggregate")) then
					(: aggregate doesn't return sequence :)
					$items
				else
					let $limit := 
						if($rqlxq("limit")) then
							$rqlxq("limit")
						else if($range) then
							rql:get-limit-from-range($range,$maxLimit)
						else
							()
					(: sort, safe to pass through :)
					let $items := rql:xq-sort($items,$rqlxq("sort"))
					(: page, safe to pass through :)
					let $items := rql:xq-limit($items, $limit)
				return
					if($items) then
						(
						<http:response status="200">
							<http:header name="Accept-Ranges" value="items"/>
							<http:header name="Content-Range" value="{rql:get-content-range-header($limit,$totalcount)}"/>
						</http:response>,
						<root xmlns:json="http://www.json.org">{
						for $node in $items return
							mdl:check-html(element {"json:value"} {
								attribute {"json:array"} {"true"},
								mdl:resolve-links(mdl:add-metadata($node,$collection,$describe),$schema,$collection,$schemastore)/node()
							},$accept)
						}</root>
						)
					else
						element {"json:value"} {
							attribute {"json:array"} {"true"}
						}
				
		else
			<http:response status="403" msg="Error: Guests are not allowed to query the entire collection"/>
};

declare function mdl:put($collection, $data, $directives) {
    let $root := $directives("root-collection")
	let $schemastore := $directives("schemastore")
	let $model := $directives("model")
	let $id := $directives("id")
	let $schema := mdl:get-schema($schemastore, $model)
	let $null := 
	    if(xmldb:collection-available($collection)) then
	        ()
	    else
	        xmldb:create-collection($root, $model)
	let $data := mdl:remove-links($data,$schema)
	let $did := $data/id/string()
	(: check if id in data:
	this will take precedence, and actually move a resource 
	from the original ID if that ID differs
	:)
	let $oldId := 
		if($did and $id and $did != $id) then
			$id
		else
			""
	let $id :=
		if($did) then
			$did
		else if($id) then
			$id
		else
			let $next-id := mdl:get-next-id($schema,$schemastore)
			return
				if($next-id) then
					$next-id
				else
					util:uuid()
	let $data := 
		if($did) then
		   $data
		else
			element {"root"} {
				$data/@*,
				$data/*[name(.) != "id"],
				element id {
					$id
				}
			}
	let $data := mdl:from-schema($data,$schema)
	let $doc :=
		if(exists(collection($collection)/root[id = $id])) then
			base-uri(collection($collection)/root[id = $id])
		else
			$id || ".xml"
	let $res := xmldb:store($collection, $doc, $data)
	return
		if($res) then
			mdl:resolve-links($data,$schema,$collection,$schemastore)
		else
			<http:response status="500" msg="Unkown Error occurred"/>
};

declare function mdl:delete($collection,$id,$directives) {
	if($id) then
		xmldb:remove($collection, $id || ".xml")
	else
		<http:response status="500" msg="Unkown Error occurred"/>
}; 

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string,$query-string as xs:string,$method as xs:string,$accept as xs:string,$data as node(),$forcexml as xs:boolean,$describe as xs:string) {
	let $root := $dataroot || "/" || $domain || "/model/"
	let $store :=  $root || $model
	let $schemastore := $root || "Class"
	let $directives := map {
	   "describe" := $describe,
	   "accept" := $accept,
	   "model" := $model,
	   "range" := string(request:get-header("Range")),
	   "schemastore" := $schemastore,
	   "root-collection" := $root,
	   "id" := $id
	}
	let $response :=
		if($model eq "") then
			<http:response status="500" msg="Unkown Error occurred"/>
		else if($method = ("PUT","POST")) then
			mdl:put($store, $data, $directives)
		else if($method="GET") then
			(: if there no query AND an id we should always return the doc :)
			if($id) then
				mdl:get($store,$id,$directives)
			(: if there is a query we should always return an array :)
			else
				mdl:query($store, $query-string, $directives)
		else if($method="DELETE") then
			mdl:delete($store,$id,$directives)
		else
			<http:response status="503" msg="Unkown Error occurred"/>
	let $output := 
		if($response and $forcexml = false() and matches($accept,"application/[json|javascript]")) then
			util:declare-option("exist:serialize","method=json media-type=application/json")
		else
			util:declare-option("exist:serialize", "method=xml media-type=application/xml")
	return
		if(name($response[1]) = "http:response") then
			(: expect custom response :)
			let $http-response := $response[1]
			let $result := remove($response,1)
			return
				(: parse http:response entry :)
				(
				    if($http-response/@status) then
    					response:set-status-code($http-response/@status)
    				else
    					(),
    				for $header in $http-response/http:header return 
    					response:set-header($header/@name,$header/@value),
    				if($result) then
    					$result
    				else
    					element response {
    						$http-response/@message/string(),
    						$http-response/message/string()
    					}
				)
		else
			$response
};

declare %private function mdl:to-plain-xml($node as element()) as item()* {
	let $name := string(node-name($node))
	let $name :=
		if($name = "json") then
			"root"
		else if($name = "pair" and $node/@name) then
			$node/@name
		else if($name = "item") then
			"json:value"
		else
			$name
	return
		if($node[@type = "array"]) then
		   for $item in $node/node() return
			element {$name} {
				attribute {"json:array"} {"true"},
				mdl:to-plain-xml($item)
			}
		else if($name="json:value") then
			if(empty($node/*)) then
				(if($node/@type = ("number","boolean")) then
					attribute {"json:literal"} {"true"}
				else
					(),
				$node/string())
			else
			   for $item in $node/node() return
					mdl:to-plain-xml($item)
		else
			element {$name} {
				if($node/@type = "array") then
					attribute {"json:array"} {"true"}
				else if($node/@type = ("number","boolean")) then
					attribute {"json:literal"} {"true"}
				else
					(),
				$node/@*[matches(name(.),"json:")],
				for $child in $node/node() return
					if($child instance of element()) then
						mdl:to-plain-xml($child)
					else
						$child
			}
};