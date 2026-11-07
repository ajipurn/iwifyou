function addToken2AllForms()
{
function doAddLogic()
{
var session_token = 'fixture-session-token-01';
var forms = document.getElementsByTagName("form");
for ( var i=0; i<forms.length; i++ )
{
var tempform = forms[i];
var sEnctype = tempform.getAttribute("enctype");
if ( sEnctype != null &&
"multipart/form-data" == sEnctype.toLowerCase() )
{
continue;
}
var tokenInput = document.createElement("input");
tokenInput.setAttribute("id", "_SESSION_TOKEN");
tokenInput.setAttribute("name", "_SESSION_TOKEN");
tokenInput.setAttribute("type", "hidden");
tokenInput.setAttribute("value", session_token);
tempform.appendChild(tokenInput);
}
}
if( window.onload == null )
{
window.onload=function(){
doAddLogic();
myOnLoad();
}
}
else
{
var tempfunction = window.onload;
window.onload=function(){
tempfunction();
doAddLogic();
myOnLoad();
}
}
}
addToken2AllForms();
