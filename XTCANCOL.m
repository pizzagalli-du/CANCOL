%
%  CANCOL Imaris XTension
%  Pizzagalli&Bordini et al., The journal of Immunology (2022)
%  Performs channel colocalization assisting the user.
%  Helpful to improve tracking or to separate objects visible in multiple
%  channels
%  
%  Revision: 202206225
%
%  Author: Pizzagalli Diego Ulisse (1,2), Joy Bordini (1), Marcus Thelen
%  (1), Rolf Krause (2), Santiago Fernandez Gonzalez (1).
%          1. USI, Institute for Research in Biomedicine
%          2. USI, Euler Institute
%
%  INSTALLATION ON COMPUTERS WITH MATLAB ALREADY INSTALLED:
%                1. Copy this file into an XTensions folder
%                   (e.g C:\Program Files\Bitplane\Imaris [ver]\XT\matlab).
%                2. Restart Imaris and you can find this function in the 
%                   IRB 2-photon toolbox menu with the "CANCOL" name.
%                NOTE: Tested with MATLAB r2017b, r2021a and Imaris 9.7.1
%
%  INSTALLATION ON COMPUTERS WITHOUT MATLAB:
%                1. Copy the compiled files SVMColor.exe and SVMColoc.xml
%                   into the compiled XTensions folder
%                   (e.g C:\Program Files\Bitplane\Imaris [ver]\XT\rtmatlab).
%                2. Restart Imaris and you can find this function in the 
%                   Image Processing menu with the "SVMColoc" name.
%                NOTE: You need the Matlab Compiler Runtime to be installed
%                      Please contact Bitplane for help.
%
%    <CustomTools>
%      <Menu name="IRB 2-photon toolbox">
%        <Item name="CANCOL RC1" icon="I"
%        tooltip="Creates an additional channel with the objects of interests only">
%          <Command>MatlabXT::XTCANCOL(%i)</Command>
%        </Item>
%      </Menu>
%    </CustomTools>
% 
%  Brief Description: Creates a new coloc channel
% 
%  License: Free to use and distribute under Creative Commmons Licence 3.0
%  http://creativecommons.org/licenses/by/3.0/

function XTCANCOL(aImarisApplicationID)

    [dir, ~, ~] = fileparts(mfilename('fullpath'));

    %% Libraries
    addpath(strcat(dir, filesep, 'icons', filesep, '32'));
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
    
    aDataSet = vImarisApplication.GetDataSet.Clone;
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
    
    W_GAUSSIAN_SMALL = 5; %um
    W_GAUSSIAN_LARGE = 9; %um

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
    img = zeros(H,W,C);
    
    SVMModel = []; %Contains the trained SVM Model
    SVMModel_RBF = [];
    is_lodaed_SVM_Model = false;
    
    %% Reading dataset
    if(C*W*H > 0)
    h = waitbar(0, 'Reading dataset from Imaris');
    z_stack_full = zeros(W,H,Z,C,T, 'uint16');

    for tt = 0:T-1 %for all the time points
        for cc=0:C-1 %for all the channels
            z_stack_full(:,:,:,cc+1,tt+1) = aDataSet.GetDataVolumeShorts(cc, tt); %read and save in z_stack_full
        end
        waitbar(tt/(T+1), h);
    end
    close(h);
    else
        errordlg('Please open a video/image before launching the plugin');
        return;
    end
    
%% Get channel LUT and contrast for visualization only
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
    
%% GUI (new version) %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    frmMain = main();

    %% Buttons for guided annotation
    frmMain.btnUpdate.ButtonPushedFcn = @(pushCalc, eventData)pushupdatecallback(pushCalc, eventData);
    
    frmMain.btnAddBrightCells.ButtonPushedFcn = @(pushCalc, eventData)pushlabel1callback(pushCalc, eventData);
    frmMain.btnAddDimCells.ButtonPushedFcn = @(pushCalc, eventData)pushlabel1callback(pushCalc, eventData);
    
    frmMain.btnAddBlebs.ButtonPushedFcn = @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData);
    frmMain.btnAddEmptyAreas.ButtonPushedFcn = @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData);
    frmMain.btnAddFibers.ButtonPushedFcn = @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData);
    frmMain.btnAddOtherCells.ButtonPushedFcn = @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData);
    frmMain.btnAddOutsideCells.ButtonPushedFcn = @(pushCalc, eventData)pushlabel2callback(pushCalc, eventData);
    
    %% Buttons to load/save SVM model
    frmMain.btnSaveModel.ButtonPushedFcn = @(pushCalc, eventData)pushSaveModelCallback(pushCalc, eventData);
    frmMain.btnLoadModel.ButtonPushedFcn = @(pushCalc, eventData)pushLoadModelCallback(pushCalc, eventData);
    
    %% Checkboxes for channel selection
    %TODO: enable channel selection to avoid using multiple times the
    %generated virtual channels (i.e. when colocalization is performed
    %multiple times)
    if(C >= 1)
        %frmMain.chkUseCh1.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 2)
        %frmMain.chkUseCh2.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 3)
        %frmMain.chkUseCh3.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 4)
        %frmMain.chkUseCh4.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 5)
        %frmMain.chkUseCh5.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 6)
        %frmMain.chkUseCh6.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 7)
        %frmMain.chkUseCh7.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C >= 8)
        %frmMain.chkUseCh8.Enable = 'on';
        frmMain.chkUseCh1.Value = true;
    end
    if(C < 1)
        errordlg('No imaging channels found. Please check that to have opened the video in Imaris');
       return;
    end
    if(C > 8)
        errordlg('Too many imaging channels to display, skipping channel 9 - ', num2str(C));
    end
    
    %% Navigation controls
    itemsZ = cell(1, Z);
    for zz = 1:Z
        itemsZ{zz} = num2str(zz);
    end
    frmMain.sldZ.Items = itemsZ;
    
    itemsT = cell(1, T);
    for tt = 1:T
        itemsT{tt} = num2str(tt);
    end
    frmMain.sldT.Items = itemsT;
    
    %% Buttons to execute training, preview and processing the entire video
    frmMain.btnUpdate.ButtonPushedFcn = @(pushCalc, eventData)pushupdatecallback(pushCalc, eventData);
    frmMain.btnProcess.ButtonPushedFcn = @(pushCalc, eventData)pushcomputecallback(pushCalc, eventData);
    frmMain.btnPreview.ButtonPushedFcn = @(pushCalc, eventData)pushpreviewcallback(pushCalc, eventData);

    %% Generate scatter plot and intensity plot
    h = waitbar(0, 'Computing scatter plot and intensity variation');
    ch_a = z_stack_full(:,:,:,1,:); %TODO: select channel
    ch_b = z_stack_full(:,:,:,2,:); %TODO: select channel
    ch_a = ch_a(:);
    ch_b = ch_b(:);

    n = size(ch_a,1);
    l = 10000;
    out = randperm(n,l);
    scatter(ch_a(out), ch_b(out), '.', 'Parent', frmMain.axColorScatter);
    clear ch_a;
    clear ch_b;
    close(h);
%% End of GUI creation %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Auxiliary functions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Update gauge balacing
function updatestats()
    if(numel(train_class) > 0)
        balancing = ((sum(train_class == 1) - sum(train_class == -1)) / numel(train_class)) * 50;
        frmMain.gagBalancing.Value = balancing;
    end
end

%% Start annotating FG
function pushlabel1callback(pushCalc, eventData)
    interactivePointSelection(1); % FG
end

%% Start annotating BG
function pushlabel2callback(pushCalc, eventData)
    interactivePointSelection(-1); % BG    
end

%% Save trained SVM model
function pushSaveModelCallback(pushCalc, eventData)
    uisave({'train_data', 'train_class'}, 'model');
end

%% Load trained SVM model
function pushLoadModelCallback(pushCalc, eventData)
    uiload();
    updatestats();
end

%% Draw annotating line
function interactivePointSelection(curr_class)
    hif = drawfreehand(frmMain.UIAxes, 'Closed', false);
    hif.InteractionsAllowed = 'none';
    if(curr_class == 1)
        hif.Color = 'y';
    else
        hif.Color = 'r';
    end
    pos_curr = hif.Position;
    x_train_curr = pos_curr(:,1);
    y_train_curr = pos_curr(:,2);

    class_curr = zeros(numel(x_train_curr), 1)+curr_class;
    updateTrainingPts(x_train_curr, y_train_curr, class_curr, curr_class);
    updatestats();
end

%% Function to update the displayed image
function pushupdatecallback(pushCalc, eventData) 
    sldT_value = round(str2num(frmMain.sldT.Value));
    if(TF < 0 || (sldT_value - 1 ~= TF))
        TF = sldT_value - 1;
        z_stack = z_stack_full(:,:,:,:,TF+1);
        h = waitbar(0, 'Computing features... ');
        z_stack_gauss_small = z_stack;
        z_stack_gauss_large = z_stack;
        %for each channel, compute features
        for cc = 1:C
            waitbar(cc/C, h);
            z_stack_gauss_small(:,:,:,cc) = imfilter(z_stack_gauss_small(:,:,:,cc), fs_gauss_small, 'symmetric');
            z_stack_gauss_large(:,:,:,cc) = imfilter(z_stack_gauss_large(:,:,:,cc), fs_gauss_large, 'symmetric');
        end
        
        bri_z = zeros(Z,1);
        for zz = 1:Z
            curr_z_stack = z_stack(:,:,zz,:);
            bri_z(zz) = mean(curr_z_stack(:));
        end
        plot(1:Z, bri_z, 'Parent', frmMain.axBrightnessZ);
        close(h);
    end    
    %z-stack plane rendering
    curr_z = round(str2num(frmMain.sldZ.Value));
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
    imshow(uint8(R), 'Parent', frmMain.UIAxes);% axis xy;
end

%% Function to update the training set with the current annotations
function updateTrainingPts(curr_x, curr_y, curr_class, class_curr)
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
            % train data is in the form of NxF where N is the number of points, and F the number of features.
            % a row looks like ch1 ch2 ch1_gauss_small ch2_gauss_small ch1_gauss_large ch2_gauss_large
            train_data(train_count,1:C) = z_stack(rx, ry, curr_z, :);
            train_data(train_count,C+1:2*C) = z_stack_gauss_small(rx, ry, curr_z, :); 
            train_data(train_count,2*C+1:3*C) = z_stack_gauss_large(rx, ry, curr_z, :);            
        end
    end
end

%% Function to apply the trained model to the currently visualized image and display the results
function pushpreviewcallback(pushCalc, eventData)
    SVMModel_RBF = fitcsvm(train_data(1:train_count, :), train_class(1:train_count), 'Standardize',true,'KernelFunction','RBF',...
    'KernelScale','auto');

    SVM_RESULT_RBF = zeros(W,H);

    TestSet = zeros(W*H, C*3);
    z_stack = z_stack_full(:,:,:,:,TF+1);
    z_stack_gauss_small = z_stack;
    z_stack_gauss_large = z_stack;
    %for each channel, compute features
    for cc = 1:C
        z_stack_gauss_small(:,:,:,cc) = imfilter(z_stack_gauss_small(:,:,:,cc), fs_gauss_small, 'symmetric');
        z_stack_gauss_large(:,:,:,cc) = imfilter(z_stack_gauss_large(:,:,:,cc), fs_gauss_large, 'symmetric');
    end
    cz = curr_z;
    for cc = 1:C
        feat_point = z_stack(:,:,cz,cc);
        feat_2d = z_stack_gauss_small(:,:,cz,cc);
        feat_3d = z_stack_gauss_large(:,:,cz,cc);

        TestSet(:,cc) = feat_point(:);
        TestSet(:,C+cc) = feat_2d(:);
        TestSet(:,2*C+cc) = feat_3d(:);
    end

    [SVM_RBF_PRED_CLASS, SVM_RBF_PRED_SCORE] = predict(SVMModel_RBF, TestSet);
    SVM_RESULT_RBF(:,:) = vec2mat(SVM_RBF_PRED_SCORE(:,2), W)';
            
    SVM_RESULT_RBF(SVM_RESULT_RBF < -1.1) = -1.1;
    SVM_RESULT_RBF(SVM_RESULT_RBF > 1.1) = 1.1;
    SVM_RESULT_RBF = mat2gray(SVM_RESULT_RBF)*255;        

    R(:,:,1) = max(R(:,:,1), uint16(SVM_RESULT_RBF'.*double(255/255)));
    R(:,:,2) = max(R(:,:,2), uint16(SVM_RESULT_RBF'.*double(100/255)));
    R(:,:,3) = max(R(:,:,3), uint16(SVM_RESULT_RBF'.*double(200/255)));
    imshow(uint8(R), 'Parent', frmMain.UIAxes); axis xy;
end

%% Function to train and apply the trained model to the entire video
function pushcomputecallback(pushCalc, eventData)
    SVMModel_RBF = fitcsvm(train_data(1:train_count, :), train_class(1:train_count), 'Standardize',true,'KernelFunction','RBF',...
    'KernelScale','auto');
    
    aDataSet.SetSizeC(C + 1);
    aDataSet.SetChannelName(C, 'CANCOL output');
    aDataSet.SetChannelColorRGBA(C, 16711935);
    aDataSet.SetChannelRange(C, 0, 255);
    
    SVM_RESULT_RBF = zeros(W,H,Z);
    TestSet = zeros(W*H, C*3);
    
    h = waitbar(0, strcat('Frame N. ', num2str(TF), ' Processing Z-plane N. ', num2str(0)));
    for TF=0:T-1
        %waitbar(TF/T, h, strcat('Getting from Imaris Frame N. ', num2str(TF)));
        z_stack = z_stack_full(:,:,:,:,TF+1);
        z_stack_gauss_small = z_stack;
        z_stack_gauss_large = z_stack;
        %for each channel, compute features
        for cc = 1:C
            z_stack_gauss_small(:,:,:,cc) = imfilter(z_stack_gauss_small(:,:,:,cc), fs_gauss_small, 'symmetric');
            z_stack_gauss_large(:,:,:,cc) = imfilter(z_stack_gauss_large(:,:,:,cc), fs_gauss_large, 'symmetric');
        end

        for cz=1:Z
            waitbar(TF/T, h, strcat('Processing Frame N. ', num2str(TF), ' , Z-plane N. ', num2str(cz)));
            for cc = 1:C
                feat_point = z_stack(:,:,cz,cc);
                feat_2d = z_stack_gauss_small(:,:,cz,cc);
                feat_3d = z_stack_gauss_large(:,:,cz,cc);
                
                TestSet(:,cc) = feat_point(:);
                TestSet(:,C+cc) = feat_2d(:);
                TestSet(:,2*C+cc) = feat_3d(:);
            end
                        
            [SVM_RBF_PRED_CLASS, SVM_RBF_PRED_SCORE] = predict(SVMModel_RBF, TestSet);
            SVM_RESULT_RBF(:,:,cz) = vec2mat(SVM_RBF_PRED_SCORE(:,2), W)';
        end
        
        SVM_RESULT_RBF(SVM_RESULT_RBF < -1.1) = -1.1;
        SVM_RESULT_RBF(SVM_RESULT_RBF > 1.1) = 1.1;
        SVM_RESULT_RBF = mat2gray(SVM_RESULT_RBF)*255;        
        aDataSet.SetDataVolumeShorts(SVM_RESULT_RBF,  C,  TF);
    end
        
    vImarisApplication.SetDataSet(aDataSet);
    
    frmMain.delete;
    close(h);
    close all;
    clear all;
    return;
end
end