%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This file is part of cocoSim.
% Copyright (C) 2014-2016  Carnegie Mellon University
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Main file for CoCoSim

function [nom_lustre_file, sf2lus_Time, nb_actions, Query_time]=cocoSim(model_full_path, const_files, default_Ts, trace, dfexport)
bdclose('all')
% Checking the number of arguments
if ~exist('trace', 'var')
    trace = false;
end

if ~exist('const_files', 'var')
    const_files = {};
end
if ~exist('dfexport', 'var')
    dfexport = false;
end
if nargin < 1
    display_help_message();
    return
end


% Get start time
t_start = now;
sf2lus_start = tic;
% Retrieving of the path containing the cocoSim file
[cocoSim_path, ~, ~] = fileparts(mfilename('fullpath'));
% Retrieving of the path containing the model for which we generate the code
[model_path, file_name, ~] = fileparts(model_full_path);

if ~exist('default_Ts', 'var')
    try
        ts = Simulink.BlockDiagram.getSampleTimes(file_name);
        default_Ts = ts(1).Value(1);
    catch
        default_Ts = 0.1;
    end
end
addpath(fullfile(cocoSim_path, 'backEnd'));
addpath(fullfile(cocoSim_path, 'middleEnd'));
addpath(fullfile(cocoSim_path, 'frontEnd'));
addpath(fullfile(cocoSim_path, 'utils'));
addpath(fullfile(cocoSim_path, '.'));

addpath(cocoSim_path);
config;
try
    SOLVER = evalin('base','SOLVER');
    RUST_GEN = evalin('base', 'RUST_GEN');
    C_GEN = evalin('base', 'C_GEN');
catch
    SOLVER = 'NONE';
    RUST_GEN = 0;
    C_GEN = 0;
end
nb_actions = 0;

config_msg = ['CoCoSim Configuration, Change this configuration in src/config.m\n'];
config_msg = [config_msg '--------------------------------------------------\n'];
config_msg = [config_msg '|  SOLVER: ' SOLVER '\n'];
config_msg = [config_msg '|  ZUSTRE: ' ZUSTRE '\n'];
config_msg = [config_msg '|  JKIND:  ' JKIND '\n'];
config_msg = [config_msg '|  KIND2:  ' KIND2 '\n'];
config_msg = [config_msg '|  LUSTREC:' LUSTREC '\n'];
config_msg = [config_msg '|  LUSTREC Include Dir:' include_dir '\n'];
config_msg = [config_msg '|  SEAHORN:' SEAHORN '\n'];
config_msg = [config_msg '|  Z3: ' Z3 '\n'];
config_msg = [config_msg '--------------------------------------------------\n'];
display_msg(config_msg, Constants.INFO, 'cocoSim', '');


msg = ['Loading model: ' model_full_path];
display_msg(msg, Constants.INFO, 'cocoSim', '');

% add path the model directory
addpath(model_path);

load_system(char(model_full_path));

% Load all intialisation values and constants
const_files_bak = const_files;
try
    const_files = evalin('base', const_files);
catch 
    const_files = const_files_bak;
end

mat_files = {};
% Are we dealing with a list of files provided by the user or just a simple file
if iscell(const_files)
    for i=1:numel(const_files)
        if strcmp(const_files{i}(end-1:end), '.m')
            evalin('base', ['run ' const_files{i} ';']);
        else
            vars = load(const_files{i});
            field_names = fieldnames(vars);
            for j=1:numel(field_names)
                % base here means the current Matlab workspace
                assignin('base', field_names{j}, vars.(field_names{j}));
            end
            mat_files{numel(mat_files) + 1} = const_files{i};
        end
    end
elseif ischar(const_files)
    if strcmp(const_files(end-1:end), '.m')
        evalin('base', ['run ' const_files ';']);
    else
        vars = load(const_files);
        field_names = fieldnames(vars);
        for j=1:numel(field_names)
            % base here means the current Matlab workspace
            assignin('base', field_names{j}, vars.(field_names{j}));
        end
        mat_files{numel(mat_files) + 1} = const_files;
    end
end

% Retrieving of the Bus structure
display_msg('Getting bus struct', Constants.INFO, 'cocoSim', '');
bus_struct = BusUtils.get_bus_struct();

% Save current path, model path and cocoSim path informations to temporary file
origin_path = pwd;
if strcmp(model_path, '')
    model_path = './';
end
save 'tmp_data' origin_path model_path cocoSim_path bus_struct

% Pre-process model
display_msg('Pre-processing', Constants.INFO, 'cocoSim', '');
new_file_name = cocosim_pp(model_full_path);

if ~strcmp(new_file_name, '')
    model_full_path = new_file_name;
    [model_path, file_name, ~] = fileparts(model_full_path);
end

% Definition of the output files names
output_dir = fullfile(model_path, strcat('lustre_files/src_', file_name));
nom_lustre_file = fullfile(output_dir, strcat(file_name, '.lus'));
mkdir(output_dir);
trace_file_name = fullfile(output_dir, strcat(file_name, '.cocosim.trace.xml'));
property_file_base_name = fullfile(output_dir, strcat(file_name, '.property'));

initialize_files(nom_lustre_file);

display_msg('Building internal format', Constants.INFO, 'cocoSim', '');
%%%%%%% Load all the systems including the referenced ones %%%%
[models, subsystems] = find_mdlrefs(file_name);

%%%%%% Internal representation building %%%%%%
[inter_blk, blks, complex_structs]= mk_internalRep(file_name, ...
    dfexport, models, ...
    subsystems, mat_files, ...
    default_Ts);

% Create traceability informations in XML format
display_msg('Start tracebility', Constants.INFO, 'cocoSim', '');
xml_trace = XML_Trace(model_full_path, trace_file_name);
xml_trace.init();

% Print bus declarations
bus_decl = write_buses(bus_struct);

%%%%%%%%%%%%%%% Retrieving nodes code %%%%%%%%%%%%%%%

display_msg('Lustre generation', Constants.INFO, 'cocoSim', '');

extern_nodes_string = '';
extern_Stateflow_nodes_fun = [];
extern_functions = {};

cpt_extern_functions = 1;
extern_matlab_functions = {};
properties_nodes_string = '';
property_node_names = {};

nodes_string = '';
cocospec = [];
print_spec = false;
is_SF = false;

for idx_subsys=numel(inter_blk):-1:1
    msg = sprintf('Compiling %s:%s', inter_blk{idx_subsys}{1}.origin_name{1}, ...
        inter_blk{idx_subsys}{1}.type{1});
    display_msg(msg, Constants.DEBUG, 'cocoSim', '');
	
    %%%%%%% Matlab functions and CoCoSpec code generation %%%%%%%%%%%%%%%
    is_matlab_function = false;
    is_cocospec = false;
    is_Chart = false;
    if idx_subsys ~= 1 && ~strcmp(inter_blk{idx_subsys}{1}.type, 'ModelReference')
        sf_sub = get_param(inter_blk{idx_subsys}{1}.annotation, 'SFBlockType');
        cocospec_name = get_param(inter_blk{idx_subsys}{1}.annotation, 'Name');
        if strcmp(cocospec_name, 'CoCoSpec')
            is_cocospec = true;
        elseif strcmp(sf_sub, 'MATLAB Function')
            is_matlab_function = true;
        elseif strcmp(sf_sub, 'Chart')
            is_Chart = true;
            is_SF = true;
        end
    end
    if is_cocospec
        display_msg('CoCoSpec Found', Constants.INFO, 'cocoSim', '');
        [contract_name, chart] = Utils.get_MATLAB_function_name(inter_blk{idx_subsys}{1});
        spec_lines = regexp(chart.Script, sprintf('\n'), 'split');
        blk_path_elems = regexp(inter_blk{idx_subsys}{1}.name{1}, '/', 'split');
        node_call_name = Utils.concat_delim(blk_path_elems, '_');
        disp(node_call_name)
        cocospec_file = fullfile(output_dir, strcat([contract_name], '_cocospec.lus'));
        raw_spec = Utils.concat_delim(spec_lines, sprintf('\n'));
        fid = fopen(cocospec_file, 'w');
        fprintf(fid, '%s', raw_spec);
        fclose(fid);
        [cocospec] = CoCoSpec.get_cocospec(cocospec_file);
        
        if isempty(cocospec)
            display_msg('NO CoCoSpec found', Constants.WARNING, 'cocoSim', '');
        else
            print_spec = true;
        end
                
    elseif is_matlab_function
        display_msg('Found Embedded Matlab', Constants.INFO, 'cocoSim', '');
        try
            [fun_name, chart] = Utils.get_MATLAB_function_name(inter_blk{idx_subsys}{1});
            [mat_fun_node] = write_matlab_function_node(inter_blk{idx_subsys}{1}, inter_blk, inter_blk{idx_subsys}, fun_name, chart, xml_trace);
            
            extern_nodes_string = [extern_nodes_string mat_fun_node];
            blk_path_elems = regexp(inter_blk{idx_subsys}{1}.name{1}, '/', 'split');
            node_call_name = Utils.concat_delim(blk_path_elems, '_');
            disp(node_call_name)
            fun_file = fullfile(output_dir, strcat([node_call_name '_' fun_name], '.m'));
            lines = regexp(chart.Script, sprintf('\n'), 'split');
            lines{1} = regexprep(lines{1}, ['= ' fun_name '('], ['= ' node_call_name '_' fun_name '(']);
            script = Utils.concat_delim(lines, sprintf('\n'));
            fid = fopen(fun_file, 'w');
            fprintf(fid, '%s', script);
            fclose(fid);
            display_msg('Successfully done processing Embedded Matlab', Constants.INFO, 'cocoSim', '');
        catch ME
            display_msg(ME.getReport(), Constants.DEBUG, 'cocoSim', '');
            display_msg(['Unable to process Embedded Matlab :' ME.message], Constants.ERROR, 'cocoSim', '');
        end
        
        
    elseif is_Chart
        display_msg('Found Stateflow', Constants.INFO, 'cocoSim', '');
        load_system(char(inter_blk{idx_subsys}{1}.origin_name));
        rt = sfroot;
        m = rt.find('-isa', 'Simulink.BlockDiagram');
        chartArray = m.find('-isa','Stateflow.Chart');
        chart = chartArray(strcmp(chartArray.get('Path'),inter_blk{idx_subsys}{1}.origin_name));
        [ block_string,external_nodes_i,nb_actions, ~] = chart2lus( chart, 0, xml_trace,file_name );
        if ~strcmp(SOLVER, 'Z') && ~strcmp(SOLVER, 'NONE')
            msg = 'Currently only Zustre can be used to verify Stateflow models';
            display_msg(msg, Constants.ERROR, 'cocoSim', '');
            return
        end
        nodes_string = [nodes_string block_string];
        extern_Stateflow_nodes_fun = [extern_Stateflow_nodes_fun, external_nodes_i];
       %%%%% Standard Simulink blocks code generation %%%%%%%%%%%%%%%
    elseif (idx_subsys == 1 || ~Constants.is_property(inter_blk{idx_subsys}{1}.mask_type)) && inter_blk{idx_subsys}{1}.num_output ~= 0
        
        if strcmp(inter_blk{idx_subsys}{1}.type, 'SubSystem')
            sf_sub = get_param(inter_blk{idx_subsys}{1}.annotation, 'SFBlockType');
            if idx_subsys == 1 && strcmp(sf_sub, 'Chart')
                load_system(char(inter_blk{idx_subsys}{1}.origin_name));
                rt = sfroot;
                m = rt.find('-isa', 'Simulink.BlockDiagram');
                chartArray = m.find('-isa','Stateflow.Chart');
                chart = chartArray(strcmp(chartArray.Path,inter_blk{idx_subsys}{1}.origin_name));
                [ block_string,external_nodes_i,nb_actions, ~] = chart2lus( chart, 0, xml_trace,file_name );
                nodes_string = [nodes_string block_string];
                extern_Stateflow_nodes_fun = [extern_Stateflow_nodes_fun, external_nodes_i];
            end
        end
    
        
        [node_header, let_tel_code, extern_s_functions_string, extern_funs, properties_nodes, property_node_name, extern_matlab_funs, c_code, external_nodes_i] = ...
            blocks2lustre(file_name, nom_lustre_file, inter_blk, blks, mat_files, idx_subsys, trace, xml_trace);
        
        extern_Stateflow_nodes_fun = [extern_Stateflow_nodes_fun, external_nodes_i];
        extern_nodes_string = [extern_nodes_string extern_s_functions_string];
        
        for idx_extern=1:numel(extern_funs)
            extern_functions{cpt_extern_functions} = extern_funs{idx_extern};
            cpt_extern_functions = cpt_extern_functions + 1;
        end
        
        for idx_ext_mat=1:numel(extern_matlab_funs)
            extern_matlab_functions{numel(extern_matlab_functions)+1} = extern_matlab_funs{idx_ext_mat};
        end 
        
        properties_nodes_string = [properties_nodes_string properties_nodes];
        if numel(property_node_name) > 0
            for idx_prop_names=1:numel(property_node_name)
                if idx_subsys == 1
                    property_node_name{idx_prop_names}.parent_node_name = file_name;
                    property_node_name{idx_prop_names}.parent_block_name = file_name;
                else
                    res = regexp(inter_blk{idx_subsys}{1}.name{1}, '/', 'split');
                    property_node_name{idx_prop_names}.parent_node_name = Utils.concat_delim(res, '_');
                    property_node_name{idx_prop_names}.parent_block_name = inter_blk{idx_subsys}{1}.origin_name{1};
                end
                property_node_names{numel(property_node_names) + 1} = property_node_name{idx_prop_names};
            end
        end
        
        nodes_string = [nodes_string node_header];
        nodes_string = [nodes_string let_tel_code];
        nodes_string = [nodes_string 'tel\n\n'];
        
    end
end


%%%%%%%%%%%%%%%%% Lustre Code Printing %%%%%%%%%%%%%%%%%%%%%%

% Open file for writing
fid = fopen(nom_lustre_file, 'a');



% add external nodes called from action like min, max and matlab functions
% or int_to_real and real_to_int
extern_Stateflow_nodes_fun_string = '';
n = numel(extern_Stateflow_nodes_fun);
functions_names = cell(n,1);
functions_names(:) = {''};
j = 1;
for i=1:n
    fun = extern_Stateflow_nodes_fun(i);
    if strcmp(fun.Name,'trigo')
            extern_functions{cpt_extern_functions} = fun.Type;
            cpt_extern_functions = cpt_extern_functions + 1;
    elseif isempty(find(strcmp(functions_names,fun.Name),1))  
        functions_names{j} = fun.Name;
        j=j+1;
        if strcmp(fun.Name,'lustre_math_fun')
            extern_Stateflow_nodes_fun_string = ['#open <math>\n', extern_Stateflow_nodes_fun_string];
            
        elseif strcmp(fun.Name,'lustre_conv_fun')
            extern_Stateflow_nodes_fun_string = ['#open <conv>\n', extern_Stateflow_nodes_fun_string];
            
        elseif strcmp(fun.Name,'after')
            extern_Stateflow_nodes_fun_string = [extern_Stateflow_nodes_fun_string temporal_operators(fun)];    
            
        else
            extern_Stateflow_nodes_fun_string = [extern_Stateflow_nodes_fun_string math_functions(fun)];
        end
    end
end

[str_include, extern_functions_string] = write_extern_functions(extern_functions, output_dir);
% Write include for external functions
if ~strcmp(str_include, '')
    fprintf(fid, str_include);
end

if ~strcmp(extern_Stateflow_nodes_fun_string, '')
    fprintf(fid, '-- External Stateflow functions\n');
    fprintf(fid, extern_Stateflow_nodes_fun_string);
end

% Write in case we have cocospec
if print_spec
    fprintf(fid, '-- CoCoSpec Start\n');
    for idx=1:numel(cocospec)
        if ~isempty(cocospec{idx})
            fprintf(fid, cocospec{idx});
        end
    end
    fprintf(fid, '-- CoCoSpec End\n');
end
% Write complex struct declarations
if ~strcmp(complex_structs, '')
    fprintf(fid, complex_structs);
end

% Write buses declarations
if ~strcmp(bus_decl, '')
    fprintf(fid, bus_decl);
end

% Write extern functions
if ~strcmp(extern_functions_string, '')
    fprintf(fid, '-- External functions\n');
    fprintf(fid, extern_functions_string);
end


% Write conversion functions
if exist('tmp_dt_conv.mat', 'file') == 2
    load 'tmp_dt_conv'
    open_conv = false;
    if exist('int_to_real') == 1 || exist('real_to_int') == 1
        fprintf(fid, print_int_to_real());
        open_conv = true;
    end
    if exist('rounding') == 1
        if ~open_conv
            fprintf(fid, print_int_to_real());
        end
        fprintf(fid, print_dt_conversion_nodes(rounding));
    end
    path = which('tmp_dt_conv.mat');
    delete(path);
end

% Write external nodes declarations
if ~strcmp(extern_nodes_string, '')
    fprintf(fid, '\n-- Extern nodes\n');
    fprintf(fid, extern_nodes_string);
end

% Write property nodes content
if ~strcmp(properties_nodes_string, '')
    fprintf(fid, '\n-- Properties nodes\n');
    fprintf(fid, properties_nodes_string);
end

% Write external matlab functions
for idx=1:numel(extern_matlab_functions)
    matlab_fle_name = fullfile(output_dir, extern_matlab_functions{idx}.name);
    fid_mat = fopen(matlab_fle_name, 'w');
    fprintf(fid_mat, extern_matlab_functions{idx}.body);
    fclose(fid_mat);
end

% Write System nodes
fprintf(fid, '\n-- System nodes\n');
fprintf(fid, nodes_string);

% Close file
fclose(fid);

display_msg('End of code generation', Constants.INFO, 'cocoSim', '');

% Write traceability informations
xml_trace.write();
msg = sprintf(' %s', trace_file_name);
display_msg(msg, Constants.INFO, 'Traceability', '');

% Generated files informations

sf2lus_Time = toc(sf2lus_start);
msg = sprintf(' %s', nom_lustre_file);
display_msg(msg, Constants.INFO, 'Lustre Code', '');


%%%%%%%%%%%%% Compilation to C or Rust %%%%%%%%%%%%%
if RUST_GEN
    display_msg('Generating Rust Code', Constants.INFO, 'Rust Compilation', '');
    try
        rust(nom_lustre_file);
    catch ME
        display_msg(ME.getReport(), Constants.DEBUG, 'Rust Compilation', '');
        display_msg(ME.message, Constants.ERROR, 'Rust Compilation', '');
    end
elseif C_GEN
    display_msg('Generating C Code', Constants.INFO, 'C Compilation', '');
    try
        lustrec(nom_lustre_file);
    catch ME
        display_msg(ME.message, Constants.ERROR, 'C Compilation', '');
        display_msg(ME.getReport(), Constants.DEBUG, 'C Compilation', '');
    end
end


%%%%%%%%%%%%% Verification %%%%%%%%%%%%%%%
smt_file = '';
Query_time = 0;
if numel(property_node_names) > 0 && not (strcmp(SOLVER, 'NONE'))
    if not (strcmp(SOLVER, 'Z') || strcmp(SOLVER,'K') || strcmp(SOLVER, 'J'))
        display_msg('Available solvers are Z for Zustre and K for Kind2', Constants.WARNING, 'cocoSim', '');
        return
    end
    if exist(c_code, 'file')
        display_msg('Running SEAHORN', Constants.INFO, 'SEAHORN', '');
        try
            smt_file = seahorn(c_code);
            if strcmp(SOLVER, 'K')
                msg = 'Kind2 does not support S-Function. Switching to Zustre.';
                display_msg(msg, Constants.WARNING, 'SEAHORN', '');
                SOLVER = 'Z';
            end
        catch ME
            display_msg(ME.message, Constants.ERROR, 'SEAHORN', '');
            display_msg(ME.getReport(), Constants.DEBUG, 'SEAHORN', '');
        end
    end
    open(models{end});
    if strcmp(SOLVER, 'Z')
        display_msg('Running Zustre', Constants.INFO, 'Verification', '');
        try
            Query_time = zustre(nom_lustre_file, property_node_names, property_file_base_name, inter_blk, xml_trace, is_SF, smt_file);
        catch ME
            display_msg(['Zustre has failed :' ME.message], Constants.ERROR, 'Verification', '');
            display_msg(ME.getReport(), Constants.DEBUG, 'Verification', '');
        end
    elseif strcmp(SOLVER, 'K')
        display_msg('Running Kind2', Constants.INFO, 'Verification', '');
        try
            kind2(nom_lustre_file, property_node_names, property_file_base_name, inter_blk, xml_trace);
        catch ME
            display_msg(ME.message, Constants.ERROR, 'Verification', '');
            display_msg(ME.getReport(), Constants.DEBUG, 'Verification', '');
        end
    elseif strcmp(SOLVER, 'J')
        display_msg('Running JKind', Constants.INFO, 'Verification', '');
        try
            jkind(nom_lustre_file, property_node_names, property_file_base_name, inter_blk, xml_trace);
        catch ME
            display_msg(ME.message, Constants.ERROR, 'Verification', '');
            display_msg(ME.getReport(), Constants.DEBUG, 'Verification', '');
        end
    end
else
    display_msg('No property to prove', Constants.INFO, 'Verification', '');
end

%%%%%%%%%%%% Cleaning and end of operations %%%%%%%%%%

    % Temporary files cleaning
    display_msg('Cleaning temporary files', Constants.INFO, 'cocoSim', '');
    if exist(strcat(origin_path,'/tmp_data.mat'), 'file') == 2
        delete(strcat(origin_path,'/tmp_data.mat'));
    end

    t_end = now;
    t_compute = t_end - t_start;
    display_msg(['Total computation time: ' datestr(t_compute, 'HH:MM:SS.FFF')], Constants.INFO, 'Time', '');

end

function display_help_message()
    msg = [ ' -----------------------------------------------------  \n'];
    msg = [msg '  CoCoSim: Automated Analysis Framework for Simulink/Stateflow\n'];
    msg = [msg '   \n Usage:\n'];
    msg = [msg '    >> cocoSim(MODEL_PATH, [MAT_CONSTANTS_FILES], [TIME_STEP], [TRACE])\n'];
    msg = [msg '\n'];
    msg = [msg '      MODEL_PATH: a string containing the path to the model\n'];
    msg = [msg '        e.g. ''cocoSim test/properties/property_2_test.mdl\''\n'];
    msg = [msg '      MAT_CONSTANT_FILES: an optional list of strings containing the\n'];
    msg = [msg '      path to the mat files containing the simulation constants\n'];
    msg = [msg '        e.g. {''../../constants1.mat'',''../../constants2.mat''}\n'];
    msg = [msg '        default: {}\n'];
    msg = [msg '      TIME_STEP: an optional numeric value for the simulation time step\n'];
    msg = [msg '        e.g. 0.1\n'];
    msg = [msg '        default: 0.1\n'];
    msg = [msg '      TRACE: a optional boolean value stating if we need to print the \n'];
    msg = [msg '      traceability informations\n'];
    msg = [msg '        e.g. true\n'];
    msg = [msg '        default: false\n'];
    msg = [msg  '  -----------------------------------------------------  \n'];
    cprintf('blue', msg);
end


function initialize_files(lustre_file)
  % Create lustre file
  fid = fopen(lustre_file, 'w');
  fprintf(fid, '-- This file has been generated by CoCoSim\n\n');
  fclose(fid);
end

function [str] = print_int_to_real()
  str = '#open <conv>\n';
end

function [nodes] = print_dt_conversion_nodes(rounding)
    load 'tmp_dt_conv'
    nodes = '';
    elems = regexp(rounding, ' ', 'split');
    if numel(elems) > 0
        elems = unique(elems);
        nodes = '-- Conversion nodes';
        for idx_round=1:numel(elems)
            % Print rounding node
            str = ['\nnode ' elems{idx_round} '(In : real)\n'];
            str = [str 'returns (Out : int)\n'];
            str = [str 'let\n\tOut = real_to_int(In);\ntel'];
            str = sprintf('%s\n', str);
            nodes = [nodes str];
        end
    end
    nodes = sprintf('%s', nodes);
end