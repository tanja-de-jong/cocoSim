function new_file = cocosim_pp(file_name, constant_file, varargin)
% PP processes a Simulink model in order to make it CoCoSim friendly.
%   It changes the differents blocks into their equivalent that is 
%   supported by CoCoSim.
%   file_name : string giving the relative path of the mdl or slx file
%   constant_file : relative path of the .m file which gives the values of
%   constants used in the model
%   Options :
%   'verif' : with this option, the process will create slx models with
%   both the block processed and the result of the processing for
%   verification purposes.

% Cleans the workspace before executing the process
% evalin('base','clear all')

% Reading options
evalin('base','global verif;');

% Getting info of this file
[pp_path, ~, ~] = fileparts(mfilename('fullpath'));

% Get the model file info
[model_path, model, ext] = fileparts(file_name);
new_file = fullfile(model_path,strcat(model, '_PP', ext));
new_model = strcat(model,'_PP');

if nargin > 2
    if strcmp(varargin{1},'verif')
        evalin('base','verif = true;');
        validation_dir = fullfile(model_path ,'PP_Validation' );
        if exist(validation_dir)==0
            mkdir(validation_dir);
        end
        addpath(validation_dir);
    else
        evalin('base','verif = false;');
    end
end

% Check if the file already exists and delete it if it does
if exist(new_file,'file') == 4
    % If it does then check whether it's open
    if bdIsLoaded(new_model)
        % If it is then close it (without saving!)
        close_system(new_model,0)
    end
    % delete the file
    delete(new_file);
end

% Add the scripts from the library to the Matlab path
% script_path = which('pp.m');
% script_path = strrep(script_path,'/pp.m','');
% % Add all subfolders of Processes into Matlab path
% addpath(genpath(strcat(script_path,'/lib')));
addpath(fullfile(pp_path, 'pp', 'lib', 'common'));
addpath(fullfile(pp_path, 'pp', 'lib', 'blocks'));
addpath(fullfile(pp_path, 'pp', 'lib', 'math'));
addpath(fullfile(pp_path, 'utils'));
% Creating a cache copy to process

display_msg(['Copying ' model ], Constants.INFO, 'simplifier', '');


copyfile(file_name, new_file);
display_msg(['Loading ' new_file ], Constants.INFO, 'simplifier', '');
load_system(new_file);
display_msg('Loading library', Constants.INFO, 'simplifier', '');
load_system('gal_lib.slx');

% Load the constant file if specified
if nargin > 1
    if not(strcmp(constant_file,''))
        % An existing file contains the constants declarations of the model
        % Add the constants of the model to the workspace
        [~, cst_name, ~] = fileparts(constant_file);
        %cst_file_name = strrep(constant_file,'.m','');
        display_msg(['Loading constants into workspace ' cst_name], Constants.INFO, 'simplifier', '');
        evalin('base', cst_name);
        fprintf('Done\n\n');
    end
end
% Load Pre-GAL default_constants file
% evalin('base','default_constants');

% Looking for GAL non-supported blocks
display_msg('Looking for CoCoSim non-supported blocks', Constants.INFO, 'simplifier', '');



% Processing Clock blocks
clock_process(new_model);

% Replace variables by their value if it is a scalar value
replace_variables(new_model);

% Processing Constant blocks
constant_process(new_model);

% Processing Deadzone blocks
deadzone_process(new_model);

% Processing Dead Zone Dynamic blocks
deadzone_dynamic_process(new_model);

% Processing Discrete Integrator blocks
discrete_integrator_process(new_model);

% Processing Discrete State Space blocks
discrete_state_space_process(new_model);

% Processing From Workspace blocks
from_workspace_process(new_model);

% Processing Function blocks
function_process(new_model);

% Processing Gain blocks
gain_process(new_model);

% Processing Goto/From pattern
goto_process(new_model);

% Processing Integrator blocks
integrator_process(new_model);

% Processing Lookup table blocks
lookuptable_process(new_model)

% Processing Lookup table n_D blocks
lookuptable_nD_process(new_model);

% Processing Math blocks with unsupported function
math_process(new_model);

% Processing RateTransition blocks
rate_transition_process(new_model);

% Processing Signal Builder blocks
signalbuilder_process(new_model);

% Processing Saturation Dynamic blocks
saturation_dynamic_process(new_model);

% Processing Saturation blocks
saturation_process(new_model);

% Processing Selector blocks
selector_process(new_model);

% Processing Transfer Functions blocks
transfer_function_process(new_model);

% Processing To Workspace blocks
to_workspace_process(new_model);

% Processing ZeroPole defined transfer functions blocks
zero_pole_process(new_model);




% Configure any subsystem to be treated as Atomic
ssys_list = find_system(new_model,'BlockType','SubSystem');
if not(isempty(ssys_list))
    display_msg('Processing Subsystem blocks', Constants.INFO, 'simplifier', ''); 
    for i=1:length(ssys_list)
        %disp(ssys_list{i})
        set_param(ssys_list{i},'TreatAsAtomicUnit','on');   
    end
    fprintf('Done\n\n');
end

% Set Inport data type to double if not defined
display_msg('Processing Inport blocks', Constants.INFO, 'simplifier', ''); 
   
inport_list = find_system(new_model,'BlockType','Inport');
if isempty(inport_list)
    display_msg('Model has no inport', Constants.WARNING, 'simplifier', '');

    %this is not good to set all auto typing to double sometime a low level
    %subsystem inherit boolean for a reset inport for an integrator, if you
    %make it double the precision of 0.0 is not the same in lustre. Boolean
    %is better
% else
%     for i=1:length(inport_list)        
%         data_type = get_param(inport_list{i},'OutDataTypeStr');
%         if strcmp(data_type,'Inherit: auto')
%             set_param(inport_list{i},'OutDataTypeStr','double')
%             block_name = get_param(inport_list{i},'Name');
%             msg = ['The data type of input "' block_name ...
%                 '" has been automatically set to "double"'];
%             display_msg(msg, Constants.WARNING, 'simplifier', '');
%         end
%     end
end

% Check if there is an output in the main block
display_msg('Checking output blocks', Constants.INFO, 'simplifier', ''); 

outport_list = find_system(new_model,'SearchDepth','1','BlockType','Outport');
if isempty(outport_list)
    %fprintf(2,'The model has no outport\n')
    display_msg('Model has no outport', Constants.WARNING, 'simplifier', '');
else
     display_msg('Model has outport', Constants.INFO, 'simplifier', '');
end


% Exporting the model to the mdl CoCoSim compatible file format

display_msg('Saving simplified model', Constants.INFO, 'simplifier', '');
disp(['Simplified model path: ' new_file])
save_system(new_model,new_file,'OverwriteIfChangedOnDisk',true);
% save_system(new_model,new_file,'ExportToVersion','R2008b');
close_system(file_name,0)

% Remove Real-time Workshop (or Simulink Coder) comments
tags = {'RTWSystemCode','MinAlgLoopOccurrences',...
    'PropExecContextOutsideSubsystem','FunctionWithSeparateData',...
    'Opaque','MaskHideContents'};
remove_line_tags(new_file,tags);

% Clean the workspace
% evalin('base','clear all');


display_msg('Done with the simplification', Constants.INFO, 'simplifier', '');
end