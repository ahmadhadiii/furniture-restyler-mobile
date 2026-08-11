#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint augen.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'augen'
  s.version          = '1.4.1'
  s.summary          = 'Flutter AR plugin using ARCore (Android), RealityKit/ARKit (iOS), and WebAssembly (web).'
  s.description      = <<-DESC
Augen is a Flutter plugin that enables pure-Dart AR development across mobile and web.
Uses RealityKit/ARKit on iOS, ARCore on Android, and a WebAssembly marker-detection
bridge on Flutter Web.
                       DESC
  s.homepage         = 'https://github.com/AminMemariani/augen'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Amin Memariani' => 'amin.memariani@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'augen/Sources/augen/**/*.swift'
  s.resource_bundles = {'augen_privacy' => ['augen/Sources/augen/Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  # Bumped from 13.0: the fork-local textured-plane path uses UnlitMaterial
  # and TextureResource.generate(from:withName:options:), both iOS 15+.
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'

  # ARKit, RealityKit, and Combine are required.
  s.frameworks = 'ARKit', 'RealityKit', 'Combine'
end
