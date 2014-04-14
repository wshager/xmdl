xquery version "3.0";

(:
 * This module provides model-based querying for XML
 :)

module namespace xmdl="http://lagua.nl/lib/xmdl";

declare namespace request="http://exist-db.org/xquery/request";
declare namespace response="http://exist-db.org/xquery/response";

import module namespace json="http://www.json.org";
import module namespace xmldb="http://exist-db.org/xquery/xmldb";
import module namespace xqjson="http://xqilla.sourceforge.net/lib/xqjson";
import module namespace xrql="http://lagua.nl/lib/xrql";

(:
Transform into xml serializable to json natively by eXist
:)

declare function xmdl:to-plain-xml($node as element()) as element()* {
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
					return xmdl:to-plain-xml($item)
		else
			element {$name} {
				if($node/@type = ("number","boolean")) then
					attribute {"json:literal"} {"true"}
				else
					(),
				$node/@*[matches(name(.),"json:")],
				for $child in $node/node() return
					if($child instance of element()) then
						xmdl:to-plain-xml($child)
					else
						$child
			}
};

declare function xmdl:check-html($node,$accept) {
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

declare function xmdl:resolve-links($node as element(), $schema as element()?, $store as xs:string, $schemastore as xs:string) as element() {
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
						let $q := xrql:parse($qstr,())
						return element { $l/rel } {
							let $href := resolve-uri($uri,$store || "/")
							let $lmodel := local:get-model-from-path($href)
							let $lschema := doc($schemastore || "/" || $lmodel || ".xml")/root
							for $x in xrql:sequence(collection($href)/root,$q,500,false()) return
								element {"json:value"} {
									attribute {"json:array"} {"true"},
									xmdl:resolve-links($x,$lschema,$href,$schemastore)/node()
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
declare function xmdl:from-schema($node as element()*, $schema as element()?) {
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
declare function xmdl:get-next-id($schema as element()?,$schemastore as xs:string,$schemaname as xs:string) {
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

declare function xmdl:remove-links($xml as node(),$schema as node()) {
	if($schema) then
		let $links := for $l in $schema/links return string($l/rel)
		element root {
			$node/@*,
			$node/node()[name(.) != $links]
		}
	else
		$node
};

declare function xmdl:request() {
	let $dataroot := "/db/data"
	return xmdl:request($dataroot)
};

declare function xmdl:request($dataroot as xs:string) {
	let $domain := request:get-server-name()
	return xmdl:request($dataroot,$domain)
};

declare function xmdl:request($dataroot as xs:string,$domain as xs:string) {
	let $model := request:get-parameter("model","")
	return xmdl:request($dataroot,$domain,$model)
};

declare function xmdl:request($dataroot as xs:string,$domain as xs:string,$model as xs:string) {
	let $accept := request:get-header("Accept")
	let $method := request:get-method()
	let $id := request:get-parameter("id","")
	let $qstr := string(request:get-query-string())
	return xmdl:request($dataroot,$domain,$model,$id[1],$method,$accept,$qstr)
};

declare function xmdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string) {
	let $data := 
		if($method = ("PUT","POST")) then
			util:binary-to-string(request:get-data())
		else
			""
	return xmdl:request($dataroot,$domain,$model,$id,$method,$accept,$qstr,$data)
};

declare function xmdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string,$data as xs:string) {
	xmdl:request($dataroot,$domain,$model,$id,$method,$accept,$qstr,$data,false())
};

declare function xmdl:request($dataroot as xs:string, $domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string,$data as xs:string,$forcexml as xs:boolean) {
	let $maxLimit := 100
	let $root := $dataroot || "/" || $domain || "/model/"
	let $store :=  $root || $model
	let $schemastore := $root || "Class"
	(: use Class/[Model] as schema internally :)
	let $schemaname := $model || ".xml"
	let $schemadoc := $schemastore || "/" || $schemaname
	let $schema := doc($schemadoc)/root
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
			let $xml := xmdl:to-plain-xml($xml)
			let $xml := xmdl:remove-links($xml,$schema)
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
				    let $next-id := xmdl:get-next-id($schema,$schemastore,$model || ".xml")
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
			let $xml := xmdl:from-schema($xml,$schema)
			let $doc :=
				if(exists(collection($store)/root[id = $id])) then
					base-uri(collection($store)/root[id = $id])
				else
					$id || ".xml"
			let $res := xmldb:store($store, $doc, $xml)
			return
				if($res) then
					xmdl:resolve-links($xml,$schema,$store,$schemastore)
				else
					response:set-status-code(500)
		else if($method="GET") then
			(: if there is a query we should always return an array :)
			if($qstr = "" and $id != "") then
				let $node := collection($store)/root[id = $id]
				return
					if($node) then
						xmdl:check-html(xmdl:resolve-links($node,$schema,$store,$schemastore),$accept)
					else
						(element root {
							"Error: " || $model || "/" || $id || " not found"
						},
						response:set-status-code(404))
			else if($qstr != "" or request:get-header("range") or sm:is-authenticated()) then
				let $q := xrql:parse($qstr,())
				let $res := for $node in xrql:sequence(collection($store)/root,$q,$maxLimit) return
					xmdl:check-html(element {"json:value"} {
						attribute {"json:array"} {"true"},
						xmdl:resolve-links($node,$schema,$store,$schemastore)/node()
					},$accept)
				return
					if($res) then
						<root xmlns:json="http://www.json.org">{$res}</root>
					else
						<root xmlns:json="http://www.json.org" json:literal="true">[]</root>
			else
				(element root {
					"Error: Guests are not allowed to query the entire collection"
				},
				response:set-status-code(403))
		else if($method="DELETE") then
			if($id != "") then
				let $path := base-uri(collection($store)/root[id = $id])
				let $parts := tokenize($path,"/")
				let $doc := $parts[last()]
				let $parts := remove($parts,last())
				let $path  := string-join($parts,"/")
				return xmldb:remove($path, $doc)
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