/**
  @file mp_getddl.sas
  @brief Extract DDL in various formats, by table or library
  @details Data Definition Language relates to a set of SQL instructions used
    to create tables in SAS or a database.  The macro can be used at table or
    library level.  The default behaviour is to create DDL in SAS format.

  Usage:

      data test(index=(pk=(x y)/unique /nomiss));
        x=1;
        y='blah';
        label x='blah';
      run;
      proc sql; describe table &syslast;

      %mp_getddl(work,test,flavour=tsql)

  @param lib libref of the library to create DDL for.  Should be assigned.
  @param ds dataset to create ddl for
  @param fref= the fileref to which to write the DDL.  If not preassigned, will
    be assigned to TEMP.
  @param flavour= The type of DDL to create (default=SAS). Supported=TSQL
  @param showlog= Set to YES to show the DDL in the log

  @version 9.3
  @author Allan Bowe
  @source https://github.com/macropeople/macrocore

**/

%macro mp_getddl(libref,ds,fref=getddl,flavour=SAS,showlog=NO
)/*/STORE SOURCE*/;

/* check fileref is assigned */
%if %sysfunc(fileref(&fref)) > 0 %then %do;
  filename &fref temp;
%end;
%if %length(&libref)=0 %then %let libref=WORK;
%let flavour=%upcase(&flavour);

proc sql noprint;
create table _data_ as
  select * from dictionary.tables
  where upcase(libname)="%upcase(&libref)"
  %if %length(&ds)>0 %then %do;
    and upcase(memname)="%upcase(&ds)"
  %end;
  ;
%local tabinfo; %let tabinfo=&syslast;

create table _data_ as
  select * from dictionary.indexes
  where upcase(libname)="%upcase(&libref)"
  %if %length(&ds)>0 %then %do;
    and upcase(memname)="%upcase(&ds)"
  %end;
  order by idxusage, indxname, indxpos
  ;
%local idxinfo; %let idxinfo=&syslast;

create table _data_ as
  select * from dictionary.columns
  where upcase(libname)="%upcase(&libref)"
  %if %length(&ds)>0 %then %do;
    and upcase(memname)="%upcase(&ds)"
  %end;
  ;
%local colinfo; %let colinfo=&syslast;
%local dsnlist;
select distinct upcase(memname) into: dsnlist
  separated by ' '
  from &syslast;
data _null_;
  file &fref;
  put "/* DDL generated by &sysuserid on %sysfunc(datetime(),datetime19.) */";
run;

%local x curds;
%if &flavour=SAS %then %do;
  data _null_;
    file &fref;
    put "proc sql;";
  run;
  %do x=1 %to %sysfunc(countw(&dsnlist));
    %let curds=%scan(&dsnlist,&x);
    data _null_;
      file &fref mod;
      set &colinfo (where=(upcase(memname)="&curds")) end=last;

      if _n_=1 then do;
        if memtype='DATA' then do;
          put "create table &libref..&curds(";
        end;
        else do;
          put "create view &libref..&curds(";
        end;
        put "    "@@;
      end;
      else put "   ,"@@;
      if length(format)>1 then fmt=" format="!!cats(format);
      len=" length="!!cats(length);
      lab=" label="!!quote(trim(label));
      if notnull='yes' then notnul=' not null';
      put name type len fmt notnul lab;
      if last then put ');';
    run;

    data _null_;
      set &idxinfo (where=(memname="&curds")) end=last;
      file &fref mod;
      by idxusage indxname;
      if unique='yes' then uniq=' unique';
      ds=cats(libname,'.',memname);
      if first.indxname then do;
        put 'create ' uniq ' index ' indxname;
        put '  on ' ds '(' name @@;
      end;
      else put ',' name @@;
      if last.indxname then put ');';
    run;
/*
    ods output IntegrityConstraints=ic;
    proc contents data=testali out2=info;
    run;
    */
  %end;
%end;
%else %if &flavour=TSQL %then %do;
  /* if schema does not exist, set to be same as libref */
  %let schema=&libref;
  proc sql noprint;
  select sysvalue into: schema
    from dictionary.libnames
    where libname="&libref" and engine='SQLSVR';
  %let schema=&schema; /* trim it  */

  %do x=1 %to %sysfunc(countw(&dsnlist));
    %let curds=%scan(&dsnlist,&x);
    data _null_;
      file &fref mod;
      put "/* DDL for &schema..&curds */";
      put 'IF EXISTS (SELECT 1';
      put '    FROM INFORMATION_SCHEMA.TABLES';
      put "    WHERE TABLE_NAME = '&curds')";
      put "  DROP TABLE [&schema].[&curds]";
      put "GO";
    run;
    data _null_;
      file &fref mod;
      set &colinfo (where=(upcase(memname)="&curds")) end=last;

      if _n_=1 then do;
        if memtype='DATA' then do;
          put "create table [&schema].[&curds](";
        end;
        else do;
          put "create view [&schema].[&curds](";
        end;
        put "    "@@;
      end;
      else put "   ,"@@;
      format=upcase(format);
      if format=:'DATETIME' then fmt='[datetime2](7)  ';
      else if type='num' then fmt='[decimal](18,2)';
      else fmt='[varchar]('!!cats(length)!!')';
      if notnull='yes' then notnul=' not null';
      put name fmt notnul;
    run;
    data _null_;
      set &idxinfo (where=(memname="&curds"));
      file &fref mod;
      by idxusage indxname;
      if unique='yes' then uniq=' unique';
      ds=cats(libname,'.',memname);
      if first.indxname and unique='yes' and nomiss='yes' then do;
        put '  constraint [' indxname '] PRIMARY KEY';
        put '  (';
        put '    [' name ']';
      end;
      else put '    ,[' name ']';
      if last.indxname then do;
        put '  )';
      end;
    run;
    data _null_;
      file &fref mod;
      put ')';
      put 'GO';
    run;

    /* add extended properties for labels */
    data _null_;
      file &fref mod;
      set &colinfo (where=(upcase(memname)="&curds" and label ne '')) end=last;
      nm=cats("N'",tranwrd(name,"'","''"),"'");
      lab=cats("N'",tranwrd(label,"'","''"),"'");
      put ' ';
      put "EXEC sys.sp_addextendedproperty ";
      put "  @name=N'MS_Description',@value=" lab ;
      put "  ,@level0type=N'SCHEMA',@level0name=N'&schema' ";
      put "  ,@level1type=N'TABLE',@level1name=N'&curds'";
      put "  ,@level2type=N'COLUMN',@level1name=" nm ;
      if last then put 'GO';
    run;
  %end;
%end;

%if &showlog=YES %then %do;
  options ps=max;
  data _null_;
    infile &fref;
    input;
    putlog _infile_;
  run;
%end;

%mend;
