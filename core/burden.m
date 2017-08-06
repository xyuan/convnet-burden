function burden(varargin)
%BURDEN compute memory and computational burden of network
%
% Copyright (C) 2017 Samuel Albanie
% All rights reserved.

  opts.gpus = 4 ;
  opts.helper = [] ;
  opts.type = 'single' ;
  opts.batchSize = 128 ;
  opts.lastConvFeats = '' ;
  opts.scales = 0.5:0.5:4 ;
  opts.modelPath = 'data/models-import/imagenet-matconvnet-alex.mat' ;
  opts = vl_argparse(opts, varargin) ;

  useGpu = numel(opts.gpus) > 0 ; dag = loadDagNN(opts) ; 

  % set options which are specific to current model
  [~,modelName,~] = fileparts(opts.modelPath) ;
  modelOpts.name = modelName ; modelOpts.inputVars = dag.getInputs() ; 
  modelOpts.lastConvFeats = getLastFullyConv(modelName, opts) ; 
  opts.modelOpts = modelOpts ; out = toAutonn(dag, opts) ; net = Net(out{:}) ;

  if useGpu, net.move('gpu') ; end
  imsz = net.meta.normalization.imageSize(1:2) ;
  base.paramMem = computeBurden(net, 'params', imsz, opts) ;
  [featMem,flops] = computeBurden(net, 'full', imsz, opts) ;
  base.featMem = featMem ; base.flops = flops ;

  % find fully convolutional component
  if ~isempty(modelOpts.lastConvFeats)
    trunk = Net(out{1}.find(modelOpts.lastConvFeats, 1)) ;
    if useGpu, trunk.move('gpu') ; end
    %trunkMem = computeMemory(trunk, 'feats', imsz, opts) ;
  else
    trunk = net ;
  end
  report(numel(opts.scales)).imsz = [] ;

  for ii = 1:numel(opts.scales)
    imsz_ = round(imsz * opts.scales(ii)) ;
    [mem, flops, lastFcSz] = computeBurden(trunk, 'feats', imsz_, opts) ;
    mem = mem * opts.batchSize ; flops = flops * opts.batchSize ;
    report(ii).imsz = sprintf('%d x %d', imsz_) ;
    report(ii).flops = readableFlops(flops) ;
    report(ii).feat = readableMemory(mem) ;
    report(ii).featSz = sprintf('%d x %d x %d', lastFcSz) ;
  end
  printReport(base, report, opts) ;
  if useGpu, trunk.move('cpu') ; end

% --------------------------------------
function printReport(base, report, opts)
% --------------------------------------
  header = sprintf('Report for %s\n', opts.modelOpts.name) ;
  fprintf('%s\n', repmat('-', 1, numel(header))) ;
  fprintf(header) ;
  fprintf('Data type of feats and params: %s\n', opts.type) ;
  fprintf('Memory used by params: %s\n', readableMemory(base.paramMem)) ;
  msg1 = 'Computing for single item batch at imsz %s: \n' ;
  msg2 = '    Memory consumed by params + full feats: %s\n' ;
  msg3 = '    Estimated total flops: %s\n' ;
  baseImsz = report(opts.scales ==1).imsz ;
  fprintf(msg1, baseImsz) ;
  fprintf(msg2, readableMemory(base.paramMem + base.featMem)) ;
  fprintf(msg3, readableFlops(base.flops)) ;
  fprintf('%s\n', repmat('-', 1, numel(header))) ;
  msg = '\nFeature extraction burden at %s with batch size %d: \n\n' ;
  fprintf(msg, opts.modelOpts.lastConvFeats, opts.batchSize) ;
  disp(struct2table(report)) ;

% -----------------------------------
function memStr = readableMemory(mem)
% -----------------------------------
% READABLEMEMORY(MEM) convert total raw bytes into more readable summary
% based on J. Henriques' autonn varDisplay() function

  suffixes = {'B ', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB'} ;
  place = floor(log(mem) / log(1024)) ;  % 0-based index into 'suffixes'
  place(mem == 0) = 0 ;  % 0 bytes needs special handling
  num = mem ./ (1024 .^ place) ; memStr = num2str(num, '%.0f') ; 
  memStr(:,end+1) = ' ' ;
  memStr = [memStr, char(suffixes{max(1, place + 1)})] ;  
  memStr(isnan(mem),:) = ' ' ;  % leave invalid values blank

% -------------------------------------
function flopStr = readableFlops(flops)
% -------------------------------------
% READABLEFLOPS(FLOPS) convert total flops into more readable summary

  suffixes = {' ', 'K', 'M', 'G', 'T', 'P', 'E', 'Z', 'Y'} ;
  place = floor(log(flops) / log(1000)) ;  % 0-based index into 'suffixes'
  place(flops == 0) = 0 ;  % 0 bytes needs special handling
  num = flops ./ (1000 .^ place) ; flopStr = num2str(num, '%.0f') ; 
  flopStr(:,end+1) = ' ' ;
  flopStr = [flopStr, char(suffixes{max(1, place + 1)}) 'FLOPS'] ;  
  flopStr(isnan(flops),:) = ' ' ;  % leave invalid values blank

% --------------------------------
function dag = loadDagNN(opts)
% --------------------------------
  stored = load(opts.modelPath) ;
  if ~isfield(stored, 'params') % simplenn
    dag = dagnn.DagNN.fromSimpleNN(stored) ;
  else
    dag = dagnn.DagNN.loadobj(stored) ;
  end

% --------------------------------
function out = toAutonn(net, opts)
% --------------------------------
% provide required helper functions for custom architectures

  args = {net} ;
  if strfind(opts.modelOpts.name, 'faster-rcnn')
    args = [args {@faster_rcnn_autonn_custom_fn}] ;
  elseif strfind(opts.modelOpts.name, 'ssd')
    args = [args {@ssd_autonn_custom_fn}] ;
  end
  out = Layer.fromDagNN(args{:}) ;

% -----------------------------------------------
function last = getLastFullyConv(modelName, opts)
% -----------------------------------------------
%GETlASTCONV - find the last convolutional layer of the network
%  GETlASTCONV(OPTS) - looks up the last "fully convolutional"
%  layer of the network architecture. This is the last layer that can
%  be computed with any input image size (fully connected layers 
%  typically break under varying input sizes).  In this function the
%  last layer is "looked up" for common architectures as a convenience.
%  However, the user may also specify the name of the layer output
%  variable directly.

  last = opts.lastConvFeats ;
  if ~isempty(last) ; return ; end
  if strcmp(modelName, 'imagenet-matconvnet-alex'), last = 'pool5' ; elseif strcmp(modelName, 'imagenet-vgg-verydeep-16'), last = 'pool5' ;
  elseif strcmp(modelName, 'imagenet-resnet-101-dag'), last = 'res5c' ;
  elseif contains(modelName, 'faster-rcnn') || contains(modelName, 'rfcn') 
    if contains(modelName, 'vggvd'), last = 'relu5_3' ; end
    if contains(modelName, 'res50'), last = 'res5c' ; end
  elseif contains(modelName, 'ssd')
    if contains(modelName, 'vggvd'), last = 'relu4_3' ; end
    if contains(modelName, 'res50'), last = 'res5c' ; end
  elseif contains(modelName, 'multipose')
    keyboard
  end
  msg = ['architecture not recognised, last fully convolutional layer must' ...
         ' be specified directly using the lastConvFeats option'] ;
  assert(~isempty(last), msg) ;

% -----------------------------------------------------------------
function [mem,flops,lastSz] = computeBurden(net, target, imsz, opts)
% -----------------------------------------------------------------

  flops = 0 ; lastSz = [] ; 
  last = opts.modelOpts.lastConvFeats ;
  params = [net.params.var] ;
  feats = find(arrayfun(@(x) ~ismember(x, params), 1:2:numel(params))) ;

  switch target
    case 'params'
      p = params ; mem = computeMemory(net, p, opts) ; return 
    case {'feats', 'full'}
      x = zeros([imsz 3], opts.type) ; 
      if numel(opts.gpus), x = gpuArray(x) ; end
      inVars = opts.modelOpts.inputVars ; args = {inVars{1}, x} ;
      if ismember('im_info', inVars) && strcmp(target, 'full') % handle custom inputs
        args = [args {'im_info', [imsz 1]}] ;
      end
      net.eval(args, 'test') ; p = feats ; lastSz = size(net.getValue(last)) ;
      mem = computeMemory(net, p, opts) ; flops = computeFlops(net) ;
    otherwise, error('%s not recognised') ;
  end

% ---------------------------------------
function mem = computeMemory(net, p, opts)
% ---------------------------------------
  switch opts.type
    case 'int8', bytes = 1 ;
    case 'uint8', bytes = 1 ;
    case 'int16', bytes = 2 ;
    case 'uint16', bytes = 2 ;
    case 'int32', bytes = 4 ;
    case 'uint32', bytes = 4 ;
    case 'int64', bytes = 8 ;
    case 'uint64', bytes = 8 ;
    case 'single', bytes = 4 ;
    case 'double', bytes = 8 ;
    otherwise, error('data type %s not recognised') ;
  end

  total = sum(arrayfun(@(x) numel(net.vars{x}), p)) ;
  mem = total * bytes ;

% ------------------------------------------
function total = computeFlops(net, varargin) 
% ------------------------------------------
  opts.includeExp = 0 ;
  opts = vl_argparse(opts, varargin) ;

  total = 0 ;
  for ii = 1:numel(net.forward)
    layer = net.forward(ii) ;
    ins = gather(net.vars(layer.inputVars)) ;
    outs = gather(net.vars(layer.outputVar)) ;
    funcStr = func2str(layer.func) ;
    switch funcStr
      case 'vl_nnconv' % count fused multiply-adds
        hasBias = (numel(ins) == 3) ;
        flops = numel(outs{1}) * numel(ins{2}(:,:,:,1)) ;
        if hasBias, flops = flops + numel(outs{1}) ; end
      case 'vl_nnrelu' % count as comparison + multiply
        flops = 2 * numel(outs{1}) ;
      case 'vl_nnpool' % assume two flops per location
        pos = find(cellfun(@(x) isequal(x, 'stride'), layer.args)) ;
        stride = layer.args{pos+1} ;
        flops = 2 * numel(outs{1}) * prod(stride) ;
      case 'vl_nnsoftmax' % counting flops for exp is a bit tricky
        if opts.includeExp
          flops = (2+1+5+1+2)*numel(outs{1}) ;
        else 
          flops = 0 ; 
        end
      case 'vl_nnbnorm_wrapper'
        flops = 0 ; % assume that these have been merged at test time
      otherwise, error('layer %s not recognised', func2str(layer.func)) ;
    end
    total = total + flops ;
  end
