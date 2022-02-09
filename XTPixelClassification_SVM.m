%
%  A simple pixel classifier to perform colocalization and improve tracking
%  Version without user assistance. For better UI and features use XTCANCOL
%  
%  Revision: 20220209
%
%  Author: Pizzagalli Diego Ulisse (1,2), Joy Bordini (1), Marcus Thelen
%  (1), Rolf Krause (2), Santiago Fernandez Gonzalez (1).
%          1. Institute for Research in Biomedicine - Bellinzona (CH)
%          2. Euler institute,
%             Universita della Svizzera italiana - Lugano (CH)
%
%  INSTALLATION ON COMPUTERS WITH MATLAB ALREADY INSTALLED:
%                1. Copy this file into the XTensions folder
%                   (e.g C:\Program Files\Bitplane\Imaris [ver]\XT\matlab).
%                2. Restart Imaris and you can find this function in the 
%                   Image Processing menu with the "Slim Pixel Classifier (SVM coloc)" name.
%                NOTE: Tested with MATLAB r2012b - r2021a
%
%  INSTALLATION ON COMPUTERS WITHOUT MATLAB:
%                1. Copy the compiled files SVMColor.exe and SVMColoc.xml
%                   into the compiled XTensions folder
%                   (e.g C:\Program Files\Bitplane\Imaris [ver]\XT\rtmatlab).
%                2. Restart Imaris and you can find this function in the 
%                   Image Processing menu with the "Slim Pixel Classifier (SVM coloc)" name.
%                NOTE: You need the Matlab Compiler Runtime to be installed
%                      Please contact Bitplane for help.
%
%    <CustomTools>
%      <Menu name="IRB 2-photon toolbox">
%        <Item name="Slim Pixel Classifier (SVM coloc)" icon="I"
%        tooltip="Creates an additional channel with the objects of interests only">
%          <Command>MatlabXT::XTPixelClassification_SVM(%i)</Command>
%        </Item>
%      </Menu>
%    </CustomTools>
% 
%  Brief Description: Creates a new coloc channel - version without user
%  assistance
% 
%  License: Free to use and distribute under Creative Commmons Licence 3.0
%  http://creativecommons.org/licenses/by/3.0/

function XTPixelClassification_SVM(aImarisApplicationID)

    [dir, ~, ~] = fileparts(mfilename('fullpath'));

    %% Libraries
    addpath(strcat(dir, filesep, 'icons'));
    
    %% Interfacing to Imaris
    if isa(aImarisApplicationID, 'Imaris.IApplicationPrxHelper')
        vImarisApplication = aImarisApplicationID;
    else
        javaaddpath ImarisLib.jar;
        vImarisLib = ImarisLib;
        if ischar(aImarisApplicationID)
            aImarisApplicationID = round(str2double(aImarisApplicationID));
        end
        vImarisApplication = vImarisLib.GetApplication(aImarisApplicationID);
    end
    
    %% Constants and global variables
    MAX_TRAINING_PTS = 1000;
    TOTAL_TRACKS = 0;
    W_GAUSSIAN_SMALL = 5; %um
    W_GAUSSIAN_LARGE = 9; %um
    
    %% Initialization
    aDataSet = vImarisApplication.GetDataSet.Clone;
    vFileName = vImarisApplication.GetCurrentFileName();
    [dir, fn, ext] = fileparts(char(vFileName));
    
    dataset_size = [aDataSet.GetSizeX, aDataSet.GetSizeY, aDataSet.GetSizeZ, aDataSet.GetSizeC, aDataSet.GetSizeT];
    
    W = dataset_size(1);
    H = dataset_size(2);
    Z = dataset_size(3);
    C = dataset_size(4);
    T = dataset_size(5);

    ExtendMinX = aDataSet.GetExtendMinX;
    ExtendMinY = aDataSet.GetExtendMinY;
    ExtendMinZ = aDataSet.GetExtendMinZ;
    
    ExtendMaxX = aDataSet.GetExtendMaxX;
    ExtendMaxY = aDataSet.GetExtendMaxY;
    ExtendMaxZ = aDataSet.GetExtendMaxZ;
    
    W_um = ExtendMaxX - ExtendMinX;
    dx = W_um / W;

    fs_gauss_small = fspecial('gaussian', max(3, round(W_GAUSSIAN_SMALL/dx)));
    fs_gauss_large = fspecial('gaussian', max(7, round(W_GAUSSIAN_LARGE/dx)));
    
    TF = -1;
    curr_z = 0;
    z_stack = []; %contains the current z_stack (3d multichannel, no time)
    z_stack_gauss_small = [];
    z_stack_gauss_large = [];

    train_data = zeros(MAX_TRAINING_PTS, C*3);
    train_class = [];
    train_count = 0;
    
    R = zeros(H,W,3,'uint16');
    SPI = zeros(H,W,3,'uint16');
    img = zeros(H,W,C);
    L = [];
    outputChannelName='Result';
    
    SVMModel = []; %Contains the trained SVM Model
    SVMModel_RBF = [];  %Contains the trained SVM Model
    
    % get channel contrast and visualization details.
    ranges = zeros(C, 2);
    colors = zeros(C, 1, 'uint32');
    rgb_colors = zeros(C, 3, 'uint8');
    visibility_cc = true(C,1);
    for cc = 0:dataset_size(4) - 1  
        visibility_cc(cc+1) = vImarisApplication.GetChannelVisibility(cc);
        ranges(cc+1, 1) = aDataSet.GetChannelRangeMin(cc);
        ranges(cc+1, 2) = aDataSet.GetChannelRangeMax(cc);
        colors(cc+1) = aDataSet.GetChannelColorRGBA(cc);
        rgb_colors(cc+1,1) = (bitand(colors(cc+1), hex2dec('FF'))/hex2dec('FF'))*255;
        rgb_colors(cc+1,2) = (bitand(colors(cc+1), hex2dec('FF00'))/hex2dec('FF00'))*255;
        rgb_colors(cc+1,3) = (bitand(colors(cc+1), hex2dec('FF0000'))/hex2dec('FF0000'))*255;
    end
    
    %% GUI (old version - without user assistance, use CANCOL for the newest GUI with assistance and navigation controls)
    desktopPos = get(0, 'MonitorPositions');
    
    guiWidth = desktopPos(1, 3)-24;
    guiHeight = desktopPos(1, 4)-100;
    guiPos = [...
        (desktopPos(1, 3) - guiWidth)/2, ...
        (desktopPos(1, 4) - guiHeight)/2, ...
        guiWidth, ...
        guiHeight];
    
    FormMeasures = figure(...
        'MenuBar', 'None', ...
        'Name', 'Settings', ...
        'NumberTitle', 'Off', ...
        'Position', guiPos, ...
        'Resize', 'On', ...
        'Tag', 'guiCenteredPlots');
    
    % Create the object selection popup menu.
    uicontrol(...
        'Background', get(FormMeasures, 'Color'), ...
        'FontSize', 12, ...
        'Foreground', 'k', ...
        'Parent', FormMeasures, ...
        'Position', [740 52 24 24], ...
        'String', 'Z', ...
        'Style', 'text', ...
        'Tag', 'textObjects')
    
    sldZ = uicontrol(...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [770 52 50 24], ...
        'Style', 'popupmenu', ...
        'String', {1:Z}, ...
        'Tag', 'sldZ', ...
        'TooltipString', 'Select current Z plane', ...
        'Value', 1);
    
    uicontrol(...
        'Background', get(FormMeasures, 'Color'), ...
        'FontSize', 12, ...
        'Foreground', 'k', ...
        'Parent', FormMeasures, ...
        'Position', [840 52 24 24], ...
        'String', 'T', ...
        'Style', 'text', ...
        'Tag', 'textObjects')
        
    sldT = uicontrol(...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [870 52 50 24], ...
        'Style', 'popupmenu', ...
        'String', {1:T}, ...
        'Tag', 'sldT', ...
        'TooltipString', 'Select current T frame', ...
        'Value', 1);
    
     sldClick = uicontrol(...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [940 52 60 24], ...
        'Style', 'popupmenu', ...
        'String', {'click','line'}, ...
        'Tag', 'sldClick', ...
        'TooltipString', 'Select click mode', ...
        'Value', 1);

    uicontrol(...
        'Callback', @(pushCalc, eventData)pushcomputecallback(pushCalc, eventData), ...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [320 40 120 48], ...
        'Style', 'pushbutton', ...
        'String', 'Start Classification.', ...
        'Tag', 'pushPlot', ...
        'TooltipString', 'Plot centered tracks');
    
    uicontrol(...
        'Callback', @(pushCalc, eventData)pushupdatecallback(pushCalc, eventData), ...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [600 40 120 48], ...
        'Style', 'pushbutton', ...
        'String', 'Update', ...
        'Tag', 'pushPlot', ...
        'TooltipString', 'Plot centered tracks');
    
    uicontrol(...
        'Background', get(FormMeasures, 'Color'), ...
        'FontSize', 10, ...
        'Foreground', 'k', ...
        'Parent', FormMeasures, ...
        'Position', [40 1 960 24], ...
        'String', 'This is an old version of the software that saves RAM and with a minimal UI without user assistance. For better user experience and features please use CANCOL', ...
        'Style', 'text', ...
        'Tag', 'textObjects')
    
    uicontrol(...
        'Callback', @(pushCalc, eventData)pushlabel1callback(pushCalc, eventData), ...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [40 40 120 48], ...
        'Style', 'pushbutton', ...
        'String', 'Annot. CELLS', ...
        'Tag', 'pushlable1', ...
        'TooltipString', 'Annotate desired objects');
    
    uicontrol(...
        'Callback', @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData), ...
        'FontSize', 12, ...
        'Parent', FormMeasures, ...
        'Position', [180 40 120 48], ...
        'Style', 'pushbutton', ...
        'String', 'Annot. BACKGROUND', ...
        'Tag', 'pushlabel2', ...
        'TooltipString', 'Annotate undesired objects');
    
    txtInstr = uicontrol(...
        'Background', get(FormMeasures, 'Color'), ...
        'FontSize', 10, ...
        'Foreground', 'k', ...
        'Parent', FormMeasures, ...
        'Position', [40 90 960 24], ...
        'String', 'Select a plane(Z) and a frame(t), then click update. To add annotations on cells or background use the respective buttons. Double click to end.', ...
        'Style', 'text', ...
        'FontWeight', 'bold', ...
        'HorizontalAlignment', 'left', ...
        'Tag', 'textObjects');

%% Helper functions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function pushlabel1callback(pushCalc, eventData)
    interactivePointSelection(1); % FG
end

function pushlabel2callback(pushCalc, eventData)
    interactivePointSelection(-1); % BG    
end

%% Function that handles clicks on the image to create the training set
function interactivePointSelection(curr_class)
    class_colors = ['g','w','r'];
    clickMode = get(sldClick, 'Value');
    
    if(clickMode == 2)
        hif = imfreehand('Closed', false);
        setColor(hif, class_colors(curr_class + 2));
        pos_curr = hif.getPosition();
        x_train_curr = pos_curr(:,1);
        y_train_curr = pos_curr(:,2);
    else
        [x_train_curr, y_train_curr] = getpts();
    end
    class_curr = zeros(numel(x_train_curr), 1)+curr_class;
    updateTrainingPts(x_train_curr, y_train_curr, class_curr, curr_class);
    hold on; plot(x_train_curr, y_train_curr, strcat('*', class_colors(curr_class + 2)));
end

%% Function to update the displayed image
function pushupdatecallback(pushCalc, eventData)
    if(TF < 0 || (get(sldT, 'Value') - 1 ~= TF))
        z_stack = zeros(W,H,Z,C, 'uint16');
        TF = get(sldT, 'Value') - 1;
        
        % get RAW data from Imaris
        h = waitbar(0, 'Getting data from Imaris... ');
        tic;
        for cc=0:C-1
            z_stack(:,:,:,cc+1) = aDataSet.GetDataVolumeShorts(cc, TF);
            waitbar(cc/C-1, h, 'Getting data from Imaris...');
        end
        toc;
        close(h);
        disp 'z stack acquired';

        h = waitbar(0, 'Computing Gaussian 2D and Gaussian 3D features... ');
        z_stack_gauss_small = z_stack;
        z_stack_gauss_large = z_stack;

        %for each channel, compute features
        for cc = 1:C
            waitbar(cc/C, h);
            z_stack_gauss_small(:,:,:,cc) = imfilter(z_stack_gauss_small(:,:,:,cc), fs_gauss_small, 'symmetric');
            z_stack_gauss_large(:,:,:,cc) = imfilter(z_stack_gauss_large(:,:,:,cc), fs_gauss_large, 'symmetric');
        end
        close(h);
    end    
    %z-stack plane rendering
    curr_z = get(sldZ, 'Value');
    R = zeros(H,W,3,'uint16');
    
    for cc=1:C
        min_int = ranges(cc,1);
        max_int = ranges(cc,2);
        m = 255 / (max_int -  min_int);
        q = (-min_int)*m;
        c_temp = (z_stack(:,:,curr_z,cc)*m) + q;
        img = z_stack(:,:,curr_z,cc);
        c_temp(c_temp <= 0) = 0;
        c_temp(c_temp >= 255) = 255;
        c_temp = c_temp';
        
        R(:,:,1) = max(R(:,:,1), (c_temp.*double(rgb_colors(cc, 1)/255)));
        R(:,:,2) = max(R(:,:,2), (c_temp.*double(rgb_colors(cc, 2)/255)));
        R(:,:,3) = max(R(:,:,3), (c_temp.*double(rgb_colors(cc, 3)/255)));
    end
    
    figure(1);
    imshow(uint8(R));
end

%% Function to update the training set with the current annotations
function updateTrainingPts(curr_x, curr_y, curr_class, class_curr)
    h=waitbar(0, 'Updating features');
    TOTAL_TRACKS = TOTAL_TRACKS + 1;
    train_class = [train_class; curr_class];
    
    line_id = zeros(numel(curr_x),1)+TOTAL_TRACKS;
    point_order = (1:numel(curr_x))';
        
    x_coor = strings(numel(curr_x),1);
    y_coor = strings(numel(curr_x),1);
 
    for ii = 1:numel(curr_x)
        rx = round(curr_x(ii));
        ry = round(curr_y(ii));
        if ((rx < W) && (ry < H) && (rx > 0) && (ry > 0))
            x_coor(ii) = string(rx);
            y_coor(ii) = string(ry);
            train_count = train_count + 1;
            train_data(train_count,1:C) = z_stack(rx, ry, curr_z, :);
            train_data(train_count,C+1:2*C) = z_stack_gauss_small(rx, ry, curr_z, :); 
            train_data(train_count,2*C+1:3*C) = z_stack_gauss_large(rx, ry, curr_z, :);
        end
    end
    close(h);
end

%% Function to train the SVM classifier and process the entire video
function pushcomputecallback(pushCalc, eventData)
    % Training
    SVMModel_RBF = fitcsvm(train_data(1:train_count, :), train_class(1:train_count), 'Standardize',true,'KernelFunction','RBF',...
    'KernelScale','auto');

    % Creating a new channel
    aDataSet.SetSizeC(C + 1);
    aDataSet.SetChannelName(C, 'COLOC SVM');
    aDataSet.SetChannelColorRGBA(C, 16711935);
    aDataSet.SetChannelRange(C, 0, 255);
    
    % Process entire video
    SVM_RESULT_RBF = zeros(W,H,Z);
    TestSet = zeros(W*H, C*3);
    
    h = waitbar(0, strcat('Frame N. ', num2str(TF), ' Processing Z-plane N. ', num2str(0)));
    for TF=0:T-1
        for cc=0:C-1
            z_stack(:,:,:,cc+1) = aDataSet.GetDataVolumeShorts(cc, TF);
        end
        
        z_stack_gauss_small = z_stack;
        z_stack_gauss_large = z_stack;
        %for each channel, compute features
        for cc = 1:C
            z_stack_gauss_small(:,:,:,cc) = imfilter(z_stack_gauss_small(:,:,:,cc), fs_gauss_small, 'symmetric');
            z_stack_gauss_large(:,:,:,cc) = imfilter(z_stack_gauss_large(:,:,:,cc), fs_gauss_large, 'symmetric');
        end

        for cz=1:Z
            waitbar(TF/T, h, strcat('Processing Frame N. ', num2str(TF), ' , Z-plane N. ', num2str(cz)));
            tic;
            for cc = 1:C %From 0.94s (for TestSetCount = 0:(W*H)-1) to 0.002s (for cc = 1:C) --> 470X
                feat_point = z_stack(:,:,cz,cc);
                feat_2d = z_stack_gauss_small(:,:,cz,cc);
                feat_3d = z_stack_gauss_large(:,:,cz,cc);
                TestSet(:,cc) = feat_point(:);
                TestSet(:,C+cc) = feat_2d(:);
                TestSet(:,2*C+cc) = feat_3d(:);
            end
            [SVM_RBF_PRED_CLASS, SVM_RBF_PRED_SCORE] = predict(SVMModel_RBF, TestSet);
            SVM_RESULT_RBF(:,:,cz) = vec2mat(SVM_RBF_PRED_SCORE(:,2), W)';
            toc;
        end
        
        SVM_RESULT_RBF(SVM_RESULT_RBF < -1.1) = -1.1;
        SVM_RESULT_RBF(SVM_RESULT_RBF > 1.1) = 1.1;
        SVM_RESULT_RBF = mat2gray(SVM_RESULT_RBF)*255;        
        aDataSet.SetDataVolumeShorts(SVM_RESULT_RBF,  C,  TF);
    end
        
    vImarisApplication.SetDataSet(aDataSet);
    if ismember(0, visibility_cc, 'rows') == 1
        for cc = 0:length(visibility_cc)-1
            vImarisApplication.SetChannelVisibility(cc,visibility_cc(cc+1));
        end
    end
    close(h);
    close all;
    clear all;
end
end