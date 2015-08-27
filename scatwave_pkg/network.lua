local complex = require 'complex'
local filters_bank = require 'filters_bank'
local wavelet_transform = require 'wavelet_transform'
local conv_lib = require 'conv_lib'
local network = torch.class('network')


function network:__init(M,N,J,dimension_mini_batch)
   --local ScatteringNetwork={J=5,M=32,N=32,dimension_mini_batch=1} -- J scale, M width, N height, K number of angles, dimension_mini_batch, the dimension after which the scattering will be batched. For instance, this means that you can batch a set of 128 color images stored in a tensor of size 128x3x256x256 by setting dimension_mini_batch=3
   
   self.M=M
   self.N=N
   self.J=J or 2
   self.type='torch.FloatTensor'
   self.myTensor=torch.FloatTensor
   self.dimension_mini_batch=dimension_mini_batch or 1
   self.fft=require 'wrapper_fft'   
      self.filters=filters_bank.morlet_filters_bank_2D(self.N,self.M,self.J,self.fft,self.myTensor)
end


function network:cuda()
   -- Should have a similar call to cuda() function in cunn   
   self.type='torch.CudaTensor'
   self.myTensor=torch.CudaTensor   
      
      -- First, we CUDArize the filters
      -- Phi   
   for l=1,#self.filters.phi.signal do
      self.filters.phi.signal[l]=self.filters.phi.signal[l]:cuda()
   end
   -- Psi
   for k=1,#self.filters.psi do
      for l=1,#self.filters.psi[k].signal do
         self.filters.psi[k].signal[l]=self.filters.psi[k].signal[l]:cuda()
      end
   end
   
   self.fft = require 'cuda/wrapper_CUDA_fft_nvidia'
end

function network:float()
   -- Should have a similar call to cuda() function in cunn   
   self.type='torch.FloatTensor'
   self.myTensor=torch.FloatTensor
   
   -- First, we deCUDArize the filters
   -- Phi   
   for l=1,#self.filters.phi.signal do
      self.filters.phi.signal[l]=self.filters.phi.signal[l]:float()
   end
   -- Psi
   for k=1,#self.filters.psi do
      for l=1,#self.filters.psi[k].signal do
         self.filters.psi[k].signal[l]=self.filters.psi[k].signal[l]:float()
      end
   end
   
   self.fft = require 'wrapper_fft'
end

function network:get_filters()
   return self.filters
end

function network:WT(image_input)
   local x={}
   x.signal=image_input
   x.res=0
   x.j=0
   return wavelet_transform.WT(x,self)
end

function network:allocate_inplace(mini_batch_dim)
   local filters=self.filters
   local myTensor=self.myTensor
   local filters_ip={}
   filters_ip.psi={}
   filters_ip.phi={}
   
   local function concatenateLongStorage(x,y)
      if(not x) then
         return y
      else
         local z=torch.LongStorage(#x+#y)
         for i=1,#x do
            z[i]=x[i]
         end   
         for i=1,#y do
            z[i+#x]=y[i]
         end
         return z
      end
   end
   
   for i=1,#filters.psi do
      filters_ip.psi[i]={}
      filters_ip.psi[i].signal={}
      filters_ip.psi[i].j=filters.psi[i].j
      for r=1,#filters.psi[i].signal do
         local tmp=complex.realize(filters.psi[i].signal[r])
         local sizes=concatenateLongStorage(mini_batch_dim,tmp:size())
         local strides=torch.LongStorage(#sizes)
         for l=1,#sizes do
            if(l<=#mini_batch_dim) then
               strides[l]=0
            else
               strides[l]=tmp:stride(l-#mini_batch_dim)
            end
         end
         filters_ip.psi[i].signal[r]=myTensor(tmp:storage(),tmp:storageOffset(),sizes,strides)
      end
   end
   
   filters_ip.phi.signal={}
   for r=1,#filters.phi.signal do
      local tmp=complex.realize(filters.phi.signal[r])
      local sizes=concatenateLongStorage(mini_batch_dim,tmp:size())
      local strides=torch.LongStorage(#sizes)
      for l=1,#sizes do
         if(l<=#mini_batch_dim) then
            strides[l]=0
         else
            strides[l]=tmp:stride(l-#mini_batch_dim)
         end
      end
      filters_ip.phi.signal[r]=myTensor(tmp:storage(),tmp:storageOffset(),sizes,strides)
      
   end
   
   
   filters_ip.J=filters.J
   filters_ip.n_f=8*8*filters.J*(filters.J-1)
   self.ip={}
   self.ip.filters=filters_ip
   
   self.ip.U1_c={}
   self.ip.U1_r={}
   self.ip.U2_c={}
   self.ip.U2_r={}
   
   for r=1,filters.size:size(1) do
      local sz_r=concatenateLongStorage(mini_batch_dim,torch.LongStorage({filters.size[r][1],filters.size[r][2]}))
      local sz_c=concatenateLongStorage(mini_batch_dim,torch.LongStorage({filters.size[r][1],filters.size[r][2],2}))
      self.ip.U1_r[r]=myTensor(sz_r)
      self.ip.U2_r[r]=myTensor(sz_r)
      self.ip.U1_c[r]=myTensor(sz_c)
      self.ip.U2_c[r]=myTensor(sz_c)
      
   end
   
   self.ip.S=myTensor(concatenateLongStorage(mini_batch_dim,torch.LongStorage({filters_ip.n_f,filters.size[filters.size:size(1)][1],filters.size[filters.size:size(1)][2]})))
   
   self.ip.xf=myTensor(concatenateLongStorage(mini_batch_dim,torch.LongStorage({filters.size[1][1],filters.size[1][2],2})))
   
end

-- Here, we minimize the creation of memory to avoid using garbage collector
function network:scat_inplace(image_input)
   assert(self.type==image_input:type(),'Not the correct type')
   local mini_batch = self.dimension_mini_batch
   local wrapper_fft=self.fft
   
   local myTensor=self.myTensor
   local xf=self.ip.xf
   local U1_c=self.ip.U1_c
   local U1_r=self.ip.U1_r
   local S=self.ip.S
   local U2_c=self.ip.U2_c
   local U2_r=self.ip.U2_r
   local ds
   local filters_ip = self.ip.filters
   local k=1
   local J=filters_ip.J

    -- FFT of the input image
   wrapper_fft.my_2D_fft_real_batch(image_input,mini_batch,xf)

   -- Compute the multiplication with xf and the LF, store it in U1_c[1]
   complex.multiply_complex_tensor_with_real_tensor_in_place(xf,filters_ip.phi.signal[1],U1_c[1])

   
   -- Compute the complex to real iFFT of U1_c[1] and store it in U1_r[1]
   wrapper_fft.my_2D_ifft_complex_to_real_batch(U1_c[1],mini_batch,U1_r[1])

   -- Store the downsample in S[k] where k is the corresponding position in the memory, k<-k+1

   ds=conv_lib.downsample_2D_inplace(U1_r[1],J-1,mini_batch,myTensor)
   ds2=ds

   S:narrow(mini_batch,k,1):copy(ds)
   k=k+1

   for j1=1,#filters_ip.psi do
      -- Compute the multiplication with xf and the filters which is real in Fourier, finally store it in U1_c[1]
      local J1=filters_ip.psi[j1].j
      complex.multiply_complex_tensor_with_real_tensor_in_place(xf,filters_ip.psi[j1].signal[1],U1_c[1])
   
      -- Since cuFFT is fast, we do not periodize the signal      
      -- Compute the iFFT of U1_c[1], and store it in U1_c[1]      
      wrapper_fft.my_2D_fft_complex_batch(U1_c[1],mini_batch,1,U1_c[1])
      -- We subsample it manually by changing its stride and store the subsampling in U1_c[j1]
      
      U1_c[J1+1]:copy(conv_lib.downsample_2D_inplace(U1_c[1],J1,mini_batch,myTensor))
      -- Compute the modulus and store it in U1_r[j1]

      complex.abs_value_inplace(U1_c[J1+1],U1_r[J1+1])

      -- Compute the Fourier transform and store it in U1_c[j1]
      wrapper_fft.my_2D_fft_real_batch(U1_r[J1+1],mini_batch,U1_c[J1+1])
       
      -- Compute the multiplication with U1_c[j1] and the LF, store it in U2_c[j1]
    --  print(U1_c[J1+1]:size())
     -- print(U2_c[J1+1]:size())
--print(filters_ip.phi.signal[J1+1]:size())
      complex.multiply_complex_tensor_with_real_tensor_in_place(U1_c[J1+1],filters_ip.phi.signal[J1+1],U2_c[J1+1])

      -- Compute the iFFT complex to real of U2_c[j1] and store it in U1_r[j1]
        
      wrapper_fft.my_2D_ifft_complex_to_real_batch(U2_c[J1+1],mini_batch,U1_r[J1+1])
              
      -- Store the downsample in S[k] where k is the corresponding position in the memory, k<-k+1
      ds=conv_lib.downsample_2D_inplace(U1_r[J1+1],J-J1-1,mini_batch,myTensor)

      S:narrow(mini_batch,k,1):copy(ds)
      k=k+1

      for j2=1,#filters_ip.psi do
        
         -- for j2
         if (filters_ip.psi[j2].j>filters_ip.psi[j1].j) then
         local J2=filters_ip.psi[j2].j
            -- Compute the multiplication with U1_c[j1] and the filters, and store it in U2_c[j1]
            complex.multiply_complex_tensor_with_real_tensor_in_place(U1_c[J1+1],filters_ip.psi[j2].signal[J1+1],U2_c[J1+1])
  
            -- Compute the iFFT of U2_c[j1], and store it in U2_c[j1]
            wrapper_fft.my_2D_fft_complex_batch(U2_c[J1+1],mini_batch,1,U2_c[J1+1])         
        
               -- Subsample it and store it in U2_c[j2]
               U2_c[J2+1]:copy(conv_lib.downsample_2D_inplace(U2_c[J1+1],J2-J1,mini_batch,myTensor))
       
            -- Compute the modulus and store it in U2_r[j2]
            complex.abs_value_inplace(U2_c[J2+1],U2_r[J2+1])
                         
            -- Compute the Fourier transform of U2_r[j2] and store it in U2_c[j2]
            wrapper_fft.my_2D_fft_real_batch(U2_r[J2+1],mini_batch,U2_c[J2+1])
     
            -- Compute the multiplication with U2_c[j2] and the LF, store it in U2_c[j2]    

           -- print(U2_c[J2+1]:size())
           -- print(filters_ip.phi.signal[J2+1]:size())
            complex.multiply_complex_tensor_with_real_tensor_in_place(U2_c[J2+1],filters_ip.phi.signal[J2+1],U2_c[J2+1])

            -- Compute the complex to real iFFT of U2_c[j2] and store it in U2_r[j2]
            wrapper_fft.my_2D_ifft_complex_to_real_batch(U2_c[J2+1],mini_batch,U2_r[J2+1])

 -- Store the downsample in S[k] where k is the corresponding position in the memory, k<-k+1
            ds=conv_lib.downsample_2D_inplace(U2_r[J2+1],J-J2-1,mini_batch,myTensor)
            S:narrow(mini_batch,k,1):copy(ds)
            k=k+1

     end
   end
      end
      
      --
      


   return S
end

-- Usual scattering
function network:scat(image_input)
   assert(self.type==image_input:type(),'Not the correct type')
   
   local mini_batch=self.dimension_mini_batch-1
   local S={}
   local U={}
   S[1]={}
   S[2]={}
   S[3]={}
   
   U[1]={}
   U[2]={}
   U[3]={}
   
   U[1][1]={}
   local res=0
   local s_pad=self.filters.size[res+1]
   U[1][1].signal=conv_lib.pad_signal_along_k(conv_lib.pad_signal_along_k(image_input, s_pad[1], 1+mini_batch,self.myTensor), s_pad[2], 2+mini_batch,self.myTensor) 
      U[1][1].res=0
   U[1][1].j=-1000 -- encode the fact to compute wavelet of scale 0
      U[1][1].mini_batch=mini_batch
   
   
   out=wavelet_transform.WT(U[1][1],self)
   
   U[2]=complex.modulus_wise(out.V)
   
   
   S[1][1]=out.A
   local ds=self.J
   S[1][1].signal=conv_lib.unpad_signal_along_k(conv_lib.unpad_signal_along_k(S[1][1].signal,image_input:size(1+mini_batch),1+mini_batch,ds,self.myTensor),image_input:size(2+mini_batch),2+mini_batch,ds,self.myTensor)
   local k=1
   for i=1,#U[2] do
      
      out=wavelet_transform.WT(U[2][i],self)
      
      S[2][i]=out.A
      S[2][i].signal=conv_lib.unpad_signal_along_k(conv_lib.unpad_signal_along_k(S[2][i].signal,image_input:size(1+mini_batch),1+mini_batch,ds,self.myTensor),image_input:size(2+mini_batch),2+mini_batch,ds,self.myTensor)
      
      
      
      for l=1,#out.V do
         U[3][k]=out.V[l]
         
         U[3][k].signal=complex.abs_value(U[3][k].signal)
         
         k=k+1
      end
   end
   
   k=1
   
   for i=1,#U[3] do
      
      out=wavelet_transform.WT(U[3][i],self,1)
      
      S[3][i]=out.A
      
      S[3][i].signal=conv_lib.unpad_signal_along_k(conv_lib.unpad_signal_along_k(S[3][i].signal,image_input:size(1+mini_batch),1+mini_batch,ds,self.myTensor),image_input:size(2+mini_batch),2+mini_batch,ds,self.myTensor)
      -- k=k+1
   end
   
   
   return S
end
return network
