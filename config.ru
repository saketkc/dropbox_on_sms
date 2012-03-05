require './drop'
require 'bundler/setup'
Bundler.require :default
require File.expand_path('drop', File.dirname(__FILE__))

run Sinatra::Application
