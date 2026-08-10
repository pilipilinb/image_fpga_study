% 读取图像
img = imread('C:\Users\Administrator\Desktop\qq.jpg');

% 获取图像尺寸
[height, width, ~] = size(img);

% 打开 COE 文件以写入数据
fileID = fopen('C:\Users\Administrator\Desktop\save.coe', 'w');

% 写入 COE 文件头部信息
fprintf(fileID, 'memory_initialization_radix=16;\n');
fprintf(fileID, 'memory_initialization_vector=\n');

% 遍历图像像素并将像素值写入 COE 文件
for i = 1:height
    for j = 1:width
        % 将像素值写入 COE 文件
        fprintf(fileID, '%02X%02X%02X,\n', img(i,j,1), img(i,j,2), img(i,j,3));  
    end
end

% 关闭 COE 文件
fclose(fileID);
disp('COE file generation complete.');
