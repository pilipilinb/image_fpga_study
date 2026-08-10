%% CSC色彩空间转换 MATLAB实现
% RGB <-> YCbCr 互转
% 来源: https://www.cnblogs.com/tiandsp/archive/2012/12/22/2829315.html
% 学习要点: 理解转换矩阵的数学原理，为FPGA定点化做准备

clear all;
close all;
clc;

%% 读取图像
img = imread('lena_color.jpg');
% img = mat2gray(img); % 任意区间映射到[0,1]
[m, n, dim] = size(img);
imshow(img);
title('原始RGB图像');

%% 提取RGB分量
img = double(img);
R = img(:,:,1);
G = img(:,:,2);
B = img(:,:,3);

%% RGB转YCbCr (ITU-R BT.601标准)
% 变换矩阵
% Y  =   0.299*R + 0.587*G + 0.114*B
% Cb = -0.1687*R - 0.3313*G + 0.5*B   + 128
% Cr =   0.5*R - 0.4187*G - 0.0813*B  + 128

Y  = zeros(m, n);  % 亮度分量
Cb = zeros(m, n);  % 蓝色色度分量
Cr = zeros(m, n);  % 红色色度分量

matrix = [ 0.299   0.587   0.114;
          -0.1687 -0.3313  0.5;
           0.5    -0.4187 -0.0813];

for i = 1:m
    for j = 1:n
        tmp = matrix * [R(i,j) G(i,j) B(i,j)]';
        Y(i,j)  = tmp(1);
        Cb(i,j) = tmp(2) + 128;  % 色度加上128偏移，使范围变为0~255
        Cr(i,j) = tmp(3) + 128;
    end
end

%% 显示YCbCr各分量
figure;
subplot(2,2,1); imshow(uint8(Y));  title('Y分量(亮度)');
subplot(2,2,2); imshow(uint8(Cb)); title('Cb分量(蓝色色度)');
subplot(2,2,3); imshow(uint8(Cr)); title('Cr分量(红色色度)');
subplot(2,2,4); imshow(uint8(cat(3,Y,Cb,Cr))); title('YCbCr合成');

%% YCbCr转RGB (逆变换验证)
matrix_inv = inv(matrix);

for i = 1:m
    for j = 1:n
        tmp = matrix_inv * [Y(i,j) Cb(i,j)-128 Cr(i,j)-128]';
        R(i,j) = tmp(1);
        G(i,j) = tmp(2);
        B(i,j) = tmp(3);
    end
end

%% 正反变换后图像应与原图一致
img(:,:,1) = R;
img(:,:,2) = G;
img(:,:,3) = B;
figure;
imshow(uint8(img));
title('YCbCr转回RGB(验证)');

%% ============================================
%  FPGA定点化验证: 模拟FPGA中的定点运算
%  系数扩大256倍，最后右移8位(除以256)
%  Y  = (77*R + 150*G + 29*B) >> 8
%  Cb = (-43*R - 85*G + 128*B) >> 8 + 128
%  Cr = (128*R - 107*G - 21*B) >> 8 + 128
%  ============================================

fprintf('=== FPGA定点化精度验证 ===\n');
test_r = 200; test_g = 100; test_b = 50;

% 浮点计算
y_float  = 0.299*test_r + 0.587*test_g + 0.114*test_b;
cb_float = -0.1687*test_r - 0.3313*test_g + 0.5*test_b + 128;
cr_float = 0.5*test_r - 0.4187*test_g - 0.0813*test_b + 128;

% 定点计算
y_fixed  = (77*test_r + 150*test_g + 29*test_b) / 256;
cb_fixed = (-43*test_r - 85*test_g + 128*test_b) / 256 + 128;
cr_fixed = (128*test_r - 107*test_g - 21*test_b) / 256 + 128;

fprintf('测试像素: R=%d, G=%d, B=%d\n', test_r, test_g, test_b);
fprintf('Y  : 浮点=%.4f, 定点=%.4f, 误差=%.4f\n', y_float, y_fixed, abs(y_float-y_fixed));
fprintf('Cb : 浮点=%.4f, 定点=%.4f, 误差=%.4f\n', cb_float, cb_fixed, abs(cb_float-cb_fixed));
fprintf('Cr : 浮点=%.4f, 定点=%.4f, 误差=%.4f\n', cr_float, cr_fixed, abs(cr_float-cr_fixed));
