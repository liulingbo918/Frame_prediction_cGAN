--[[
    Copyright (c) 2015-present, Facebook, Inc.
    All rights reserved.

    This source code is licensed under the BSD-style license found in the
    LICENSE file in the root directory of this source tree. An additional grant
    of patent rights can be found in the PATENTS file in the same directory.
]]--

require 'torch'
torch.setdefaulttensortype('torch.FloatTensor')
local ffi = require 'ffi'
local class = require('pl.class')
local dir = require 'pl.dir'
local tablex = require 'pl.tablex'
local argcheck = require 'argcheck'
require 'sys'
require 'xlua'
require 'image'
require 'string'

local dataset = torch.class('dataLoader')

-- list_file = '/nfs/hn38/users/xiaolonw/COCO/coco-master/train_genlist.txt'
-- path_dataset = '/scratch/xiaolonw/coco/gen_imgs/'

-- list_file = '/nfs/hn38/users/xiaolonw/COCO/coco-master/train_genlist_all_img.txt'
-- path_dataset = '/scratch/xiaolonw/coco/gen_imgs_all2/'

-- list_file = '/nfs/hn38/users/xiaolonw/VOCcode/trainval_bbox.txt'
-- path_dataset = '/scratch/xiaolonw/voc/VOC2007_gen/'

list_file = '../train_genlist_all_img.txt'
lbl_list_file = '../label_all_img.txt'
path_dataset = '/scratch/hongyuz/gen_imgs_all3/'


local initcheck = argcheck{
   pack=true,
   help=[[
     A dataset class for images in a flat folder structure (folder-name is class-name).
     Optimized for extremely large datasets (upwards of 14 million images).
     Tested only on Linux (as it uses command-line linux utilities to scale up)
]],
   {check=function(paths)
       local out = true;
       for k,v in ipairs(paths) do
          if type(v) ~= 'string' then
             print('paths can only be of string input');
             out = false
          end
       end
       return out
   end,
    name="paths",
    type="table",
    help="Multiple paths of directories with images"},

   {name="sampleSize",
    type="table",
    help="a consistent sample size to resize the images"},

   {name="split",
    type="number",
    help="Percentage of split to go to Training"
   },

   {name="samplingMode",
    type="string",
    help="Sampling mode: random | balanced ",
    default = "balanced"},

   {name="verbose",
    type="boolean",
    help="Verbose mode during initialization",
    default = false},

   {name="loadSize",
    type="table",
    help="a size to load the images to, initially",
    opt = true},

   {name="forceClasses",
    type="table",
    help="If you want this loader to map certain classes to certain indices, "
       .. "pass a classes table that has {classname : classindex} pairs."
       .. " For example: {3 : 'dog', 5 : 'cat'}"
       .. "This function is very useful when you want two loaders to have the same "
    .. "class indices (trainLoader/testLoader for example)",
    opt = true},

   {name="sampleHookTrain",
    type="function",
    help="applied to sample during training(ex: for lighting jitter). "
       .. "It takes the image path as input",
    opt = true},

   {name="sampleHookTest",
    type="function",
    help="applied to sample during testing",
    opt = true},
}

function dataset:__init(...)

   -- argcheck
   local args =  initcheck(...)
   print(args)
   for k,v in pairs(args) do self[k] = v end

   if not self.loadSize then self.loadSize = self.sampleSize; end

   if not self.sampleHookTrain then self.sampleHookTrain = self.defaultSampleHook end
   if not self.sampleHookTest then self.sampleHookTest = self.defaultSampleHook end

   local wc = 'wc'
   local cut = 'cut'
   local find = 'find'


   -- find the image path names
   self.imagePath = torch.CharTensor()  -- path to each image in dataset
   self.labelPath = torch.CharTensor() -- class index of each image (class index in self.classes)
   self.lblset = torch.IntTensor()

   --==========================================================================
   print('load the large concatenated list of sample paths to self.imagePath')
   local maxPathLength = tonumber(sys.fexecute(wc .. " -L '"
                                                  .. list_file .. "' |"
                                                  .. cut .. " -f1 -d' '")) * 2 + #path_dataset + 1
   local length = tonumber(sys.fexecute(wc .. " -l '"
                                           .. list_file .. "' |"
                                           .. cut .. " -f1 -d' '"))
   assert(length > 0, "Could not find any image file in the given input paths")
   assert(maxPathLength > 0, "paths of files are length 0?")
   self.imagePath:resize(length, maxPathLength):fill(0)
   self.lblset:resize(length):fill(0)


   local s_data = self.imagePath:data()
   local count = 0
   local labelname
   local filename
   local lbl 

    f = assert(io.open(list_file, "r"))
    for i = 1, length do 

      -- get name
      list = f:read("*line")
      cnt = 0 
      for str in string.gmatch(list, "%S+") do
        -- print(str)
        cnt = cnt + 1
        if cnt == 1 then 
          filename = str
        elseif cnt == 2 then 
          lbl= tonumber(str)
        end

      end
      assert(cnt == 2)

      filename = path_dataset .. filename  
      ffi.copy(s_data, filename)
      s_data = s_data + maxPathLength

      self.lblset[i] = lbl


      if i % 10000 == 0 then
        print(i)
        print(ffi.string(torch.data(self.imagePath[i])))
        -- print(ffi.string(torch.data(self.labelPath[i])) )

      end
      count = count + 1

    end

    f:close()
    self.numSamples = self.imagePath:size(1)

   -- if self.split == 100 then
      self.testIndicesSize = 0
   -- else
      
   -- end
end

-- size(), size(class)
function dataset:size(class, list)
   return self.numSamples
end

-- getByClass
function dataset:getByClass(class)
   local idx = torch.random(1, (#(self.imagePath))[1] )
   local imgpath = ffi.string(torch.data(self.imagePath[idx]))
   -- local lblpath = ffi.string(torch.data(self.labelPath[idx]))
   local lblnum = self.lblset[idx] 
   -- if class == 1 then
   --      print(imgpath)
   -- end
   return self:sampleHookTrain(imgpath, lblnum) 
end


-- converts a table of samples (and corresponding labels) to a clean tensor
local function tableToOutput(self, dataTable, nowlbls)
   local data, labels
   local quantity = #dataTable
   assert(dataTable[1]:dim() == 3)
   data = torch.Tensor(quantity, self.sampleSize[1], self.sampleSize[2], self.sampleSize[3])
   lbltensor = torch.Tensor(quantity, opt.classnum) 
   lbltensor:fill(0)
   for i=1,#dataTable do
      data[i]:copy(dataTable[i])
      lbltensor[{{i},{nowlbls[i]}}] = 1
   end
   return data, lbltensor
end


-- converts a table of samples (and corresponding labels) to a clean tensor
function dataset:getname(idx) 
  local nows = ffi.string(torch.data(self.imagePath[idx]))
  nows = string.sub(nows, string.len(path_dataset) + 1, -1)
  return nows
end





-- sampler, samples from the training set.
function dataset:sample(quantity)
   assert(quantity)
   -- print( (#(self.imagePath))[1]  )
   local dataTable = {}
   local nowlbls = torch.IntTensor(quantity)
   for i=1,quantity do
      local img, lblnum = self:getByClass(i)
      table.insert(dataTable, img)
      nowlbls[i] = lblnum
   end

   local data, lbltensor = tableToOutput(self, dataTable, nowlbls)
   return data, lbltensor

end

function dataset:get(i1, i2)
   local indices = torch.range(i1, i2);
   local quantity = i2 - i1 + 1;
   assert(quantity > 0)
   -- now that indices has been initialized, get the samples
   local dataTable = {}
   local nowlbls = torch.IntTensor(quantity)
   for i=1,quantity do
      -- load the sample
      local imgpath = ffi.string(torch.data(self.imagePath[indices[i]]))
      local lblnum =  self.lblset[indices[i]] 
      local img, lbl = self:sampleHookTrain(imgpath, lblnum)
      table.insert(dataTable, img)
      nowlbls[i] = lblnum
   end
   local data, lbltensor = tableToOutput(self, dataTable, nowlbls)
   return data, lbltensor
end

return dataset
