xquery version "3.0";

declare namespace text="http://exist-db.org/xquery/text";
declare namespace transform="http://exist-db.org/xquery/transform";
declare namespace request="http://exist-db.org/xquery/request";
declare namespace response="http://exist-db.org/xquery/response";

import module namespace json="http://www.json.org";
import module namespace xmldb="http://exist-db.org/xquery/xmldb";
import module namespace xqjson="http://xqilla.sourceforge.net/lib/xqjson";
import module namespace xrql="http://lagua.nl/lib/xrql";

declare function local:request($domain as xs:string,$model as xs:string,$id as xs:string,$method as xs:string,$accept as xs:string,$qstr as xs:string) {
	let $maxLimit := 100
	let $root := "/db/apps/" || $domain || "/model/"
	let $store :=  $root || $model
	let $schemastore := $root || "Class"
	let $schemadoc := $schemastore || "/" || $model || ".xml"
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
	let $null :=
		if(matches($accept,"application/[json|javascript]")) then
			util:declare-option("exist:serialize", "method=json media-type=application/json")
		else if(matches($accept,"[text|application]/xml")) then
			util:declare-option("exist:serialize", "method=xml media-type=application/xml")
		else if(matches($accept,"text/html")) then
			util:declare-option("exist:serialize", "method=html media-type=text/html")
		else
			()
	return
		if($model eq "") then
			response:set-status-code(500)
		else if($method = ("PUT","POST")) then
			let $data := util:binary-to-string(request:get-data())
			let $data := 
				if($data != "") then
					$data
				else
					"{}"
			let $xml := xqjson:parse-json($data)
			let $xml := local:to-plain-xml($xml)
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
			let $doc :=
				if(exists(collection($store)/root[id = $id])) then
					base-uri(collection($store)/root[id = $id])
				else
					$id || ".xml"
			let $res := xmldb:store($store, $doc, $xml)
			return
				if($res) then
					$xml
				else
					response:set-status-code(500)
		else if($method="GET") then
			if($id != "") then
				local:check-html(collection($store)/root[id = $id],$accept)
			else if($qstr ne "" or request:get-header("range") or sm:is-authenticated()) then
				let $q := xrql:parse($qstr,())
				return
					element {"root"} {
						for $x in xrql:sequence(collection($store)/root,$q,$maxLimit) return
							local:check-html(element {"json:value"} {
								attribute {"json:array"} {"true"},
								if($schema) then local:resolve-links($x,$schema,$store)/node() else $x/node()
							},$accept)
					}
			else
				(element {"root"} {
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
};


let $dataroot := "/db/data"
let $domain := "xmdl-test"
let $model := "test"
let $accept := request:get-header("Accept")
let $method := request:get-method()
let $id := request:get-parameter("id","")
let $qstr := string(request:get-query-string())

return local:request($dataroot,$domain,$model,$id[1],$method,$accept,$qstr)
