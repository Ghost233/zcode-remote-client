## v1.1.10

- 修复 Android 上「页面缩放」完全无效的问题：Android WebView 对根元素（<html>）的 CSS 缩放不生效，现改为作用于 <body>，与「可视缩放」各自独立、可叠加
