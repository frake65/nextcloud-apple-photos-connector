<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Command;
use OCA\ApplePhotosConnector\Service\AlbumResolutionService;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\{InputArgument,InputInterface};
use Symfony\Component\Console\Output\OutputInterface;
final class AlbumTestResolveCommand extends Command {
 public function __construct(private AlbumResolutionService $resolver){parent::__construct('apple-photos-connector:album:test-resolve');}
 protected function configure():void{$this->setDescription('Resolve one inventoried Apple album (development test)')->addArgument('sourceAlbumId',InputArgument::REQUIRED)->addArgument('userId',InputArgument::REQUIRED);}
 protected function execute(InputInterface $i,OutputInterface $o):int{try{$r=$this->resolver->resolve((int)$i->getArgument('sourceAlbumId'),(string)$i->getArgument('userId'));foreach(['source_album_id','source_id','display_name','source_album_key','nextcloud_album_id','created_or_reused']as$k)$o->writeln($k.': '.$r[$k]);return Command::SUCCESS;}catch(\Throwable$e){$o->writeln('<error>'.$e->getMessage().'</error>');return Command::FAILURE;}}
}
