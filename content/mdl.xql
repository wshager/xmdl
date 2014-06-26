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
import module namespace rql="http://lagua.nl/lib/rql";

(:
Transform into xml serializable to json natively by eXist
:)

declare function mdl:to-plain-xml($node as element()) as element()* {
	let $name := string(node-name($node))
	let $name :=
		if($name = "json") then
			"root"
		else if($name = "pair" and $node/@name) then
			$node/@name
		else
			$name
	return
		if($node[@type = "array"]) then
			for $item in $node/node() return
				let $item := element {$name} {
					attribute {"json:array"} {"true"},
						$item/node()
					}
					return mdl:to-plain-xml($item)
		else
			element {$name} {
				if($node/@type = ("number","boolean")) then
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

declare function local:replace-vars($str as xs:string, $node as element()) {
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

declare function local:get-model-from-path($path) {
    let $parts := tokenize($path,"/")
    let $last := $parts[last()]
    let $parts := remove($parts,count($parts))
    return
        if($last!="") then
            $last
        else if(count($parts)>0) then
            local:get-model-from-path(string-join($parts,"/"))
        else
            ()
};

declare function mdl:resolve-links($node as element(), $schema as element()?, $store as xs:string, $schemastore as xs:string) as element() {
	if($schema) then
		element root {
			$node/@*,
			$node/node(),
			for $l in $schema/links return
				let $href := tokenize($l/href,"\?")
				let $uri := local:replace-vars(string($href[1]),$node)
				let $qstr := local:replace-vars(string($href[2]),$node)
				return
					if($l/resolution eq "lazy") then
						let $href := 
							if($qstr) then
								$uri || "?" || $qstr
							else
								$uri
						return
							element { $l/rel } {
								element { "_ref" } { $href }
							}
					else if($l/resolution eq "eager") then
						let $q := rql:parse($qstr,())
						return element { $l/rel } {
							let $href := resolve-uri($uri,$store || "/")
							let $lmodel := local:get-model-from-path($href)
							let $lschema := doc($schemastore || "/" || $lmodel || ".xml")/root
							let $data := rql:sequence(collection($href)/root,$q,500,false())
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
declare function mdl:get-next-id($schema as element()?,$schemastore as xs:string,$schemaname as xs:string) {
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
                return xmldb:store($schemastore,$schemaname,$schema)
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
			element root {
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

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string,$qstr as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,$qstr,request:get-method())
};

declare function mdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string,$id as xs:string,$qstr as xs:string,$method as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,$qstr,$method,request:get-header("Accept"))
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$qstr as xs:string,$method as xs:string,$accept as xs:string) {
	let $data := 
		if($method = ("PUT","POST")) then
			util:binary-to-string(request:get-data())
		else
			""
	return mdl:request($dataroot,$domain,$model,$id,$qstr,$method,$accept,$data)
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$qstr as xs:string,$method as xs:string,$accept as xs:string,$data as xs:string) {
	mdl:request($dataroot,$domain,$model,$id,$qstr,$method,$accept,$data,false())
};

declare function mdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$qstr as xs:string,$method as xs:string,$accept as xs:string,$data as xs:string,$forcexml as xs:boolean) {
	let $maxLimit := 100
	let $root := $dataroot || "/" || $domain || "/model/"
	let $store :=  $root || $model
	let $schemastore := $root || "Class"
	(: use Class/[Model] as schema internally :)
	let $schemaname := $model || ".xml"
	let $schemadoc := $schemastore || "/" || $schemaname
	let $schema := 
		if(doc-available($schemadoc)) then
			doc($schemadoc)/root
		else
			()
	let $maxLimit :=
		if($schema/maxCount) then
			number($schema/maxCount)
		else
			$maxLimit
	let $result :=
		if($model eq "") then
			response:set-status-code(500)
		else if($method = ("PUT","POST")) then
			let $data := 
				if($data != "") then
					$data
				else
					"{}"
			let $xml := xqjson:parse-json($data)
			let $xml := mdl:to-plain-xml($xml)
			let $xml := mdl:remove-links($xml,$schema)
			let $did := $xml/id/text()
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
				    let $next-id := mdl:get-next-id($schema,$schemastore,$model || ".xml")
				    return
	    			    if($next-id) then
				            $next-id
				        else
					        util:uuid()
			let $xml := 
				if($did) then
				   $xml
				else
					element {"root"} {
						$xml/@*,
						$xml/*[name(.) != "id"],
						element id {
							$id
						}
					}
			let $xml := mdl:from-schema($xml,$schema)
			let $doc :=
				if(exists(collection($store)/root[id = $id])) then
					base-uri(collection($store)/root[id = $id])
				else
					$id || ".xml"
			let $res := xmldb:store($store, $doc, $xml)
			return
				if($res) then
					mdl:resolve-links($xml,$schema,$store,$schemastore)
				else
					response:set-status-code(500)
		else if($method="GET") then
			(: if there is a query we should always return an array :)
			if($qstr = "" and $id != "") then
				let $node := doc($store || "/" || $id || ".xml")/root
				return
					if($node) then
						mdl:check-html(mdl:resolve-links($node,$schema,$store,$schemastore),$accept)
					else
						(element root {
							"Error: " || $model || "/" || $id || " not found"
						},
						response:set-status-code(404))
			else if($qstr != "" or request:get-header("range") or sm:is-authenticated()) then
				let $q := rql:parse($qstr,())
				let $q2 := rql:to-xq($q/args)
				let $res := rql:apply-xq(collection($store)/root,$q2,$maxLimit)
				let $res := 
					if($q2/special/args) then
						$res
					else
						for $node in $res return
							mdl:check-html(element {"json:value"} {
								attribute {"json:array"} {"true"},
								mdl:resolve-links($node,$schema,$store,$schemastore)/node()
							},$accept)
				let $res := 
					if($res) then
						$res
					else
						element {"json:value"} {
							attribute {"json:array"} {"true"}
						}
				return
					<root xmlns:json="http://www.json.org">{$res}</root>
			else
				(element root {
					"Error: Guests are not allowed to query the entire collection"
				},
				response:set-status-code(403))
		else if($method="DELETE") then
			if($id != "") then
				let $doc := $id || ".xml"
				return xmldb:remove($store, $doc)
			else
				response:set-status-code(500)
		else
			response:set-status-code(500)
	return
		if($result and $forcexml = false() and matches($accept,"application/[json|javascript]")) then
			(
				(:response:set-header("content-type","application/json"),
				replace(util:serialize($result,"method=json media-type=application/json"),"&quot;_ref&quot;","&quot;\$ref&quot;"),:)
				util:declare-option("exist:serialize","method=json media-type=application/json"),
				$result
			)
		else
			(
				util:declare-option("exist:serialize", "method=xml media-type=application/xml"),
				$result
			)
};