
/*****************************************************************************/
/*																			 */
/* Filename: exec_task.sas													 */
/* Created: Mark Flentge, SAS Institute										 */
/* Description: Execute a CI360 Task and run until completed				 */
/* Change history:															 */
/* 24.02.2023 / Intial version,  Mark Flentge (snlmaf)						 */
/*																			 */
/*****************************************************************************/

/*options mprint mlogic symbolgen;*/
/*TESTSETSES*/

/* snlmaf: Retrieve an authentication token using a client ID and a secret key */

%macro get_authentication_token;

	data _null_;
		header='{"alg":"HS256","typ":"JWT"}';
		payload='{"clientID":"' || strip(symget("DSC_TENANT_ID")) || '"}';
		encHeader =translate(put(strip(header ),$base64x64.), "-_ ", "+/=");
		encPayload=translate(put(strip(payload),$base64x64.), "-_ ", "+/=");
		key=put(strip(symget("DSC_SECRET_KEY")),$base64x100.);
		digest=sha256hmachex(strip(key),catx(".",encHeader,encPayload), 0);
		encDigest=translate(put(input(digest,$hex64.),$base64x100.), "-_ ", "+/=");
		token=catx(".", encHeader,encPayload,encDigest);
		call symputx("DSC_AUTH_TOKEN",token,'G');
	run;

%mend;

/* snlmaf: Extracts the secret key, tenant ID and gateway host from properties file */

filename cre '/sas/software/360/CI360Direct/credentials.properties';

data _null_;
	infile cre;
	input;

	if index(_INFILE_,'clientSecret=') then
		do;
			value = substr(_infile_, index(_infile_, 'clientSecret=') + length('clientSecret='));
			call symputx("DSC_SECRET_KEY",scan(value, 1, ';'));
		end;
run;

%put &=DSC_SECRET_KEY;
filename sec '/sas/software/360/CI360Direct/cionprem.properties';

data _null_;
	infile sec;
	input;

	if index(_INFILE_,'tenantID=') then
		do;
			value = substr(_infile_, index(_infile_, 'tenantID=') + length('tenantID='));
			call symputx("DSC_TENANT_ID",scan(value, 1, ';'));
		end;

	if index(_INFILE_,'gatewayHost=') then
		do;
			value = substr(_infile_, index(_infile_, 'gatewayHost=') + length('gatewayHost='));
			call symputx("External_gateway","https://"!!scan(value, 1, ';'));
		end;
run;

%put &=DSC_TENANT_ID;
%put &=External_gateway;

%get_authentication_token;

/* snlmaf: Submit the taskId to CI360 */

%let taskId=&sysparm;
%let  marketingDesign_URL=&External_gateway./marketingExecution/taskJobs;

filename json_in temp;

data _null_;
	length text textresolved $200;
	infile cards truncover;
	file json_in;
	input text $200.;
	textresolved=resolve(text);
	put textresolved;
	cards;
{
  "taskId": "&taskId",
  "overrideSchedule": true
}
;
run;

/* snlmaf: Read response and fetch taskjobid */

filename outfile temp;
%put &=marketingDesign_URL;

PROC HTTP method='post' out=outfile in=json_in
	ct="application/json"
	url="&marketingDesign_URL";
	headers "Authorization" = "Bearer &DSC_AUTH_TOKEN.";
run;

libname respo json fileref=outfile;

proc copy inlib=respo outlib=work;
run;

proc sql noprint;
	select taskjobid into : taskjobid  from work.root;
quit;

/* snlmaf: %Loop macro retrieves the status of the task job CI360 until the task job is no longer running */

%let marketingDesign_URL=&External_gateway./marketingExecution/taskJobs/&taskjobid;
%let executionState=In progress;

%macro loop;
	%do %while (&executionState=In progress);
		filename outfile temp;
		%put &=marketingDesign_URL;

		PROC HTTP method='get' out=outfile in=json_in
			ct="application/json"
			url="&marketingDesign_URL";
			headers "Authorization" = "Bearer &DSC_AUTH_TOKEN.";
		run;

		libname respo json fileref=outfile;

		proc copy inlib=respo outlib=work;
		run;

		data _null_;
			set work.root;
			rc=SLEEP(10,1);
			call symputx("executionState",executionState);
			if executionState='Failure' then
			abort abend 2;
		run;

		%put &=executionState;
	
	%end;
%mend;

%loop;